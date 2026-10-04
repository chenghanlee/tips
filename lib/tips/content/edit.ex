defmodule Tips.Content.Edit do
  @moduledoc """
  Reads edit forms and saves guarded text edits for `Tips.Content`.

  See "Editing" in `Tips.Content`. The form is one statement joining the
  author, the content row and its attached media, so its fields, version and
  attachments come from one database snapshot.

  An edit is admitted, then checked for complete intent and a supported
  selection. One transaction locks the author, then the content row, and
  checks eligibility, ownership, deletion and the expected version before it
  compares intent. Only text changes are saved: the retained attachments must
  be submitted unchanged. A failed guard rolls back; fresh reads then report
  the current eligibility, access or version conflict.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Ecto.Changeset
  alias Tips.Accounts
  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.{Intent, Projection, Publication, Review, Search, Tip}
  alias Tips.Content.Media.Asset
  alias Tips.Repo

  require Logger

  # Positive bigint ids; anything else cannot name a row.
  @row_ids 1..9_223_372_036_854_775_807

  @guards [:unauthenticated, :unconfirmed, :forbidden, :not_found, :conflict]

  @doc "See `Tips.Content.get_edit_form/3`."
  @spec get_form(Scope.t() | nil, Tips.Content.kind(), term()) ::
          {:ok, Tips.Content.edit_form()}
          | {:error, :unauthenticated | :not_found | :outcome_unknown}
  def get_form(scope, kind, id) do
    unknown_on_database_error(fn ->
      with {:ok, user} <- author(scope),
           {:ok, kind} <- kind(kind),
           {:ok, id} <- read_id(id) do
        kind |> snapshot(user.id, id) |> Repo.all() |> form(kind)
      end
    end)
  end

  @doc "See `Tips.Content.edit_tip/5` and `Tips.Content.edit_review/5`."
  @spec edit(Scope.t() | nil, Tips.Content.kind(), term(), term(), term(), term()) ::
          {:ok, Tips.Content.edit_receipt()} | {:error, Tips.Content.edit_error()}
  def edit(scope, kind, id, expected_version, attrs, uploads) do
    unknown_on_database_error(fn ->
      with {:ok, user} <- author(scope),
           :ok <- Publication.admit(scope),
           {:ok, id} <- write_id(id),
           {:ok, attrs} <- validate(kind, expected_version, attrs, uploads) do
        kind
        |> save(user.id, id, expected_version, attrs, uploads)
        |> settle(kind, user.id, id)
      end
    end)
  end

  defp author(%Scope{user: %User{id: id} = user}) when is_integer(id), do: {:ok, user}
  defp author(_scope), do: {:error, :unauthenticated}

  defp kind(kind) when kind in [:tip, :review], do: {:ok, kind}
  defp kind(_kind), do: {:error, :not_found}

  # The readers' id forms: an integer or a decimal string.
  defp read_id(value) do
    case Ecto.Type.cast(:id, value) do
      {:ok, id} when id in @row_ids -> {:ok, id}
      _invalid -> {:error, :not_found}
    end
  end

  defp write_id(id) when is_integer(id) and id in @row_ids, do: {:ok, id}
  defp write_id(_id), do: {:error, :not_found}

  ## Form

  defp snapshot(kind, user_id, id) do
    from(c in schema(kind),
      join: u in User,
      on: u.id == c.user_id and is_nil(u.deleted_at),
      left_join: a in Asset,
      on:
        field(a, ^parent_key(kind)) == c.id and is_nil(a.cleanup_at) and
          not is_nil(a.position),
      where: c.id == ^id and c.user_id == ^user_id and is_nil(c.deleted_at),
      order_by: a.position,
      select: {c, u, a}
    )
  end

  defp form([], _kind), do: {:error, :not_found}

  defp form([{row, user, _asset} | _] = rows, kind) do
    assets = for {_row, _user, %Asset{} = asset} <- rows, do: asset
    {:ok, form(kind, Scope.for_user(user), row, assets)}
  end

  defp form(kind, scope, row, assets) do
    %{
      kind: kind,
      id: row.id,
      tip_id: tip_id(row),
      edit_version: row.edit_version,
      state: state(row),
      base: %{attrs: Map.take(row, Intent.fields(kind)), uploads: retained(assets)},
      media: Projection.media(scope, row, assets),
      capabilities: Projection.capabilities(scope, row)
    }
  end

  defp retained(assets), do: Enum.map(assets, &{:retained, &1.id, &1.description})

  ## Validation before the transaction

  defp validate(kind, expected_version, attrs, uploads) do
    attrs = if is_map(attrs), do: attrs, else: %{}

    changeset =
      kind
      |> schema()
      |> struct()
      |> change()
      |> validate_complete(Intent.fields(kind), attrs)
      |> validate_version(expected_version)
      |> validate_selection(uploads)

    if changeset.valid?,
      do: {:ok, Map.take(attrs, Intent.fields(kind))},
      else: {:error, %{changeset | action: :update}}
  end

  defp validate_complete(changeset, fields, attrs) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      if Map.has_key?(attrs, field),
        do: changeset,
        else: add_error(changeset, field, "is missing", validation: :intent)
    end)
  end

  defp validate_version(changeset, version) when is_integer(version) and version > 0,
    do: changeset

  defp validate_version(changeset, _version),
    do: add_error(changeset, :edit_version, "is invalid")

  # Text edits keep the saved selection. Anything that would add an attachment
  # is rejected here; the comparator would treat a staged video id as retained.
  defp validate_selection(changeset, uploads) when is_list(uploads) do
    uploads
    |> Enum.reverse()
    |> Enum.reduce(changeset, fn upload, changeset ->
      case selection_error(upload) do
        nil -> changeset
        {message, keys} -> add_error(changeset, :uploads, message, keys)
      end
    end)
  end

  defp validate_selection(changeset, _uploads), do: add_error(changeset, :uploads, "is invalid")

  defp selection_error({:retained, id, description})
       when is_integer(id) and (is_binary(description) or is_nil(description)),
       do: nil

  defp selection_error({:staged_video, id}), do: {"is not supported yet", media_id: id}

  defp selection_error({:image_file, slot, _file, _description}),
    do: {"is not supported yet", slot: slot}

  defp selection_error({:missing_image, slot}), do: {"must be selected again", slot: slot}
  defp selection_error(_malformed), do: {"is invalid", []}

  ## Transaction

  defp save(kind, user_id, id, expected_version, attrs, uploads) do
    Repo.transact(fn ->
      with :ok <- Publication.lock_author(user_id),
           {:ok, row} <- lock_content(kind, user_id, id),
           :ok <- check_version(row, expected_version) do
        apply_intent(kind, row, attrs, uploads)
      end
    end)
  end

  # An equivalent current intent writes nothing; anything else is a real edit.
  defp apply_intent(kind, row, attrs, uploads) do
    current = row |> attached() |> retained()
    saved = %{attrs: Map.take(row, Intent.fields(kind)), uploads: current}

    if Intent.compare(kind, saved, %{attrs: attrs, uploads: uploads}) == :equivalent do
      {:ok, {:noop, row}}
    else
      row
      |> content_changeset(attrs)
      |> validate_retained(current, uploads)
      |> Map.put(:action, :update)
      |> write(kind)
    end
  end

  # After a wait, the lock rechecks owner and deletion on the row's newest version.
  defp lock_content(kind, user_id, id) do
    query =
      from(c in schema(kind),
        where: c.id == ^id and c.user_id == ^user_id and is_nil(c.deleted_at),
        lock: "FOR NO KEY UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  defp check_version(%{edit_version: version}, version), do: :ok
  defp check_version(_row, _expected_version), do: {:error, :conflict}

  defp attached(row) do
    Repo.all(
      from(a in Asset,
        where:
          field(a, ^parent_key(row)) == ^row.id and is_nil(a.cleanup_at) and
            not is_nil(a.position),
        order_by: a.position
      )
    )
  end

  defp content_changeset(%Tip{} = tip, attrs), do: Tip.changeset(tip, attrs)
  defp content_changeset(%Review{} = review, attrs), do: Review.changeset(review, attrs)

  # Under the content lock and after the version check, the submitted
  # selection must be the complete saved one: same ids, order and descriptions.
  defp validate_retained(changeset, current, uploads) do
    if normalize(current) == normalize(uploads) do
      changeset
    else
      Enum.reduce(retained_errors(current, uploads), changeset, fn {message, keys}, changeset ->
        add_error(changeset, :uploads, message, keys)
      end)
    end
  end

  defp normalize(selection) do
    Enum.map(selection, fn {:retained, id, description} ->
      {id, if(is_binary(description) and String.trim(description) != "", do: description)}
    end)
  end

  defp retained_errors(current, uploads) do
    current_ids = Enum.map(current, &elem(&1, 1))
    submitted = normalize(uploads)
    submitted_ids = Enum.map(submitted, &elem(&1, 0))
    saved = Map.new(normalize(current))

    removed = for id <- current_ids -- submitted_ids, do: {"cannot be removed yet", media_id: id}
    added = for id <- submitted_ids -- current_ids, do: {"is not attached", media_id: id}

    changed =
      for {id, description} <- submitted,
          Map.has_key?(saved, id) and saved[id] != description,
          do: {"description cannot be changed yet", media_id: id}

    case removed ++ added ++ changed do
      [] -> [{"cannot be reordered yet", []}]
      errors -> errors
    end
  end

  # Equality with the locked row's version is already proven, so this is the
  # single compare-and-increment.
  defp write(%Changeset{valid?: false} = changeset, _kind), do: {:error, changeset}

  defp write(changeset, kind) do
    with :ok <- Publication.lock_active_choices(changeset, kind),
         {:ok, row} <-
           changeset
           |> optimistic_lock(:edit_version)
           |> put_change(:edited_at, DateTime.utc_now(:second))
           |> Repo.update(stale_error_field: :edit_version) do
      :ok = write_search(kind, row.id)
      {:ok, {:updated, row}}
    end
  end

  defp write_search(:tip, id), do: Search.write_tip_text(id)
  defp write_search(:review, id), do: Search.write_review_text(id)

  ## Result

  defp settle({:ok, {outcome, row}}, kind, _user_id, _id) do
    {:ok,
     %{
       outcome: outcome,
       kind: kind,
       id: row.id,
       tip_id: tip_id(row),
       edit_version: row.edit_version,
       state: state(row)
     }}
  end

  defp settle({:error, reason}, kind, user_id, id) when reason in @guards,
    do: recover(kind, user_id, id)

  defp settle({:error, %Changeset{} = changeset}, kind, user_id, id) do
    if stale?(changeset), do: recover(kind, user_id, id), else: {:error, changeset}
  end

  defp stale?(changeset),
    do: Enum.any?(changeset.errors, fn {_field, {_message, keys}} -> keys[:stale] end)

  # The attempt rolled back. Fresh reads report the current authorized state;
  # an author who may still edit the content had a stale version.
  defp recover(kind, user_id, id) do
    with {:ok, user} <- current_user(user_id),
         :ok <- Accounts.check_eligibility(user, :contribute),
         true <-
           Repo.exists?(
             from(c in schema(kind),
               where: c.id == ^id and c.user_id == ^user_id and is_nil(c.deleted_at)
             )
           ) do
      {:error, :conflict}
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp current_user(id) do
    case Repo.get(User, id) do
      nil -> {:error, :unauthenticated}
      user -> {:ok, user}
    end
  end

  defp schema(:tip), do: Tip
  defp schema(:review), do: Review

  defp parent_key(:tip), do: :tip_id
  defp parent_key(:review), do: :review_id
  defp parent_key(%Tip{}), do: :tip_id
  defp parent_key(%Review{}), do: :review_id

  defp tip_id(%Tip{id: id}), do: id
  defp tip_id(%Review{tip_id: id}), do: id

  defp state(%{dead_at: %DateTime{}}), do: :hidden
  defp state(_row), do: :live

  # A database error or lost connection leaves the outcome unknown, never rejected.
  defp unknown_on_database_error(fun) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error("Edit outcome unknown: #{database_reason(error)}")
      {:error, :outcome_unknown}
  end

  # Postgres details can quote submitted values; log only the code and message.
  defp database_reason(%Postgrex.Error{postgres: %{code: code, message: message}}),
    do: "#{code}: #{message}"

  defp database_reason(error), do: Exception.message(error)
end
