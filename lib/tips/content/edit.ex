defmodule Tips.Content.Edit do
  @moduledoc """
  Reads editable snapshots and saves guarded text edits for `Tips.Content`.

  See "Editing" and "Transaction participants" in `Tips.Content`. The form is
  one statement, so the account, fields, version and attachments come from one
  snapshot. An edit validates complete intent, then passes write admission.
  One transaction then locks the author and the direct tip or review, never a
  review's parent, and rechecks eligibility, ownership, deletion and the
  expected version. A failed guard rolls back, then a fresh statement names the
  rejection from current state. Only an actual change writes: the content with
  one version increment and `edited_at`, then its search text. Media changes
  are not supported yet: the saved selection must be kept unchanged.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Ecto.Changeset
  alias Tips.Accounts
  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.{Intent, Projection, Publication, Review, Search, Tip}
  alias Tips.Content.Media.Asset
  alias Tips.Repo

  @fields %{
    tip: [:title, :body, :tag_id, :model_id, :model_other, :environment_id, :prompt, :output],
    review: [:body, :model_id, :model_other, :environment_id, :prompt, :output]
  }

  # Positive bigint ids; anything else cannot name a row.
  @row_ids 1..9_223_372_036_854_775_807

  @doc "See `Tips.Content.get_edit_form/3`."
  @spec get_form(Scope.t() | nil, Tips.Content.kind(), term()) ::
          {:ok, Tips.Content.edit_form()}
          | {:error, :unauthenticated | :not_found | :outcome_unknown}
  def get_form(scope, kind, id) when is_map_key(@fields, kind) do
    Publication.unknown_on_database_error(fn ->
      with {:ok, user_id} <- author_id(scope),
           {:ok, id} <- row_id(id) do
        kind |> snapshot(id, user_id) |> form(kind)
      end
    end)
  end

  @doc "See `Tips.Content.edit_tip/5` and `Tips.Content.edit_review/5`."
  @spec edit(Scope.t() | nil, Tips.Content.kind(), term(), term(), term(), term()) ::
          {:ok, Tips.Content.edit_receipt()} | {:error, Tips.Content.edit_error()}
  def edit(scope, kind, id, expected_version, attrs, uploads) when is_map_key(@fields, kind) do
    Publication.unknown_on_database_error(fn ->
      with {:ok, user_id} <- author_id(scope),
           {:ok, id} <- row_id(id),
           {:ok, params} <- validate(kind, expected_version, attrs, uploads),
           :ok <- Publication.admit(scope) do
        write(kind, user_id, id, expected_version, params, uploads)
      end
    end)
  end

  defp author_id(%Scope{user: %User{id: id}}) when is_integer(id), do: {:ok, id}
  defp author_id(_scope), do: {:error, :unauthenticated}

  defp row_id(value) do
    case Ecto.Type.cast(:id, value) do
      {:ok, id} when id in @row_ids -> {:ok, id}
      _invalid -> {:error, :not_found}
    end
  end

  ## Form

  # One row per current attachment, or one row with no asset, all from one statement.
  defp snapshot(kind, id, user_id) do
    parent = if kind == :tip, do: :tip_id, else: :review_id

    Repo.all(
      from(c in schema(kind),
        join: u in User,
        on: u.id == c.user_id,
        left_join: a in Asset,
        on: field(a, ^parent) == c.id and is_nil(a.cleanup_at) and not is_nil(a.position),
        where: c.id == ^id and c.user_id == ^user_id and is_nil(c.deleted_at),
        order_by: a.position,
        select: {c, u, a}
      )
    )
  end

  defp form([], _kind), do: {:error, :not_found}

  defp form([{_row, %User{deleted_at: %DateTime{}}, _asset} | _rows], _kind),
    do: {:error, :unauthenticated}

  defp form([{row, user, _asset} | _rows] = rows, kind) do
    assets = for {_row, _user, %Asset{} = asset} <- rows, do: asset
    scope = Scope.for_user(user)

    {:ok,
     %{
       kind: kind,
       id: row.id,
       tip_id: tip_id(row),
       edit_version: row.edit_version,
       state: state(row),
       base: saved_intent(kind, row, assets),
       media: Projection.media(scope, row, assets),
       capabilities: Projection.capabilities(scope, row)
     }}
  end

  defp saved_intent(kind, row, assets) do
    %{
      attrs: Map.take(row, @fields[kind]),
      uploads: Enum.map(assets, &{:retained, &1.id, &1.description})
    }
  end

  ## Input

  defp validate(kind, expected_version, attrs, uploads) do
    attrs = if is_map(attrs), do: attrs, else: %{}

    changeset =
      kind
      |> edit_changeset(struct(schema(kind)), Map.take(attrs, @fields[kind]))
      |> validate_intent(@fields[kind], attrs)
      |> validate_version(expected_version)
      |> validate_uploads(uploads)

    if changeset.valid?,
      do: {:ok, Map.take(attrs, @fields[kind])},
      else: {:error, %{changeset | action: :update}}
  end

  defp validate_intent(changeset, fields, attrs) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      if Map.has_key?(attrs, field),
        do: changeset,
        else: add_error(changeset, field, "is missing", validation: :intent)
    end)
  end

  defp validate_version(changeset, version) when is_integer(version) and version in @row_ids,
    do: changeset

  defp validate_version(changeset, _version),
    do: add_error(changeset, :edit_version, "is invalid")

  # Text edits keep the saved selection; the locked comparison checks it. Any
  # other slot is rejected here, in selection order. Anything but a proper list
  # is invalid as a whole.
  defp validate_uploads(changeset, uploads) do
    case upload_errors(uploads, []) do
      :invalid ->
        add_error(changeset, :uploads, "is invalid")

      errors ->
        Enum.reduce(errors, changeset, fn {message, keys}, changeset ->
          add_error(changeset, :uploads, message, keys)
        end)
    end
  end

  # Errors collect in reverse; adding them prepends, restoring selection order.
  defp upload_errors([], errors), do: errors

  defp upload_errors([upload | rest], errors) do
    case upload_error(upload) do
      :ok -> upload_errors(rest, errors)
      error -> upload_errors(rest, [error | errors])
    end
  end

  defp upload_errors(_not_a_list, _errors), do: :invalid

  defp upload_error({:retained, id, nil}) when is_integer(id) and id > 0, do: :ok

  defp upload_error({:retained, id, description})
       when is_integer(id) and id > 0 and is_binary(description) do
    if String.valid?(description), do: :ok, else: {"is invalid", media_id: id}
  end

  defp upload_error({:missing_image, slot}), do: {"must be selected again", slot: slot}
  defp upload_error({:staged_video, media_id}), do: {"is not supported yet", media_id: media_id}

  defp upload_error({:image_file, slot, _file, _description}),
    do: {"is not supported yet", slot: slot}

  defp upload_error(_malformed), do: {"is invalid", []}

  ## Locked write

  # Any rejection rolls back. A failed guard (an atom) is then named from the
  # current state, read in a fresh statement; the expected version is kept.
  defp write(kind, user_id, id, expected_version, params, uploads) do
    case Repo.transact(fn -> save(kind, user_id, id, expected_version, params, uploads) end) do
      {:error, %Changeset{} = changeset} ->
        {:error, %{changeset | action: :update}}

      {:error, guard} when is_atom(guard) ->
        {:error, current_rejection(kind, user_id, id, expected_version, guard)}

      {:ok, receipt} ->
        {:ok, receipt}
    end
  end

  # Eligibility, then the target, then the version, as under the locks. When
  # the current state passes them all, the guard that failed at its decision
  # point stands.
  defp current_rejection(kind, user_id, id, expected_version, guard) do
    query =
      from(u in User,
        left_join: c in ^schema(kind),
        on: c.id == ^id,
        where: u.id == ^user_id,
        select: {u, c}
      )

    case Repo.one(query) do
      nil -> :unauthenticated
      {user, content} -> rejection(user, content, expected_version, guard)
    end
  end

  defp rejection(user, content, expected_version, guard) do
    user_id = user.id

    case {Accounts.check_eligibility(user, :contribute), content} do
      {{:error, ineligible}, _content} -> ineligible
      {:ok, %{user_id: ^user_id, deleted_at: nil, edit_version: ^expected_version}} -> guard
      {:ok, %{user_id: ^user_id, deleted_at: nil}} -> :conflict
      {:ok, _missing_foreign_or_deleted} -> :not_found
    end
  end

  defp save(kind, user_id, id, expected_version, params, uploads) do
    with :ok <- Publication.lock_author(user_id),
         {:ok, row} <- lock_content(kind, id, user_id),
         :ok <- check_version(row, expected_version) do
      saved = saved_intent(kind, row, attachments(kind, row.id))

      # Same attrs on both sides, so this compares only the selection.
      cond do
        Intent.compare(kind, saved, %{saved | uploads: uploads}) != :equivalent ->
          {:error, add_error(change(row), :uploads, "cannot be changed yet")}

        Intent.compare(kind, saved, %{attrs: params, uploads: uploads}) == :equivalent ->
          {:ok, receipt(:noop, kind, row)}

        true ->
          update(kind, row, expected_version, params)
      end
    end
  end

  # Ownership and the parent never change, so only the direct row is locked.
  defp lock_content(kind, id, user_id) do
    case Repo.one(from(c in schema(kind), where: c.id == ^id, lock: "FOR NO KEY UPDATE")) do
      %{user_id: ^user_id, deleted_at: nil} = row -> {:ok, row}
      _missing_foreign_or_deleted -> {:error, :not_found}
    end
  end

  # A stale version conflicts even when the values are equal; never substitute
  # the current version.
  defp check_version(%{edit_version: version}, version), do: :ok
  defp check_version(_row, _expected_version), do: {:error, :conflict}

  defp attachments(kind, id) do
    parent = if kind == :tip, do: :tip_id, else: :review_id

    Repo.all(
      from(a in Asset,
        where: field(a, ^parent) == ^id and is_nil(a.cleanup_at) and not is_nil(a.position),
        order_by: a.position
      )
    )
  end

  # The locked row holds the expected version, so the optimistic lock is the
  # one compare-and-increment.
  defp update(kind, row, expected_version, params) do
    changeset =
      kind
      |> edit_changeset(%{row | edit_version: expected_version}, params)
      |> put_change(:edited_at, DateTime.utc_now(:second))
      |> optimistic_lock(:edit_version)

    with :ok <- Publication.lock_active_choices(changeset, kind),
         {:ok, row} <- update_row(changeset) do
      :ok = write_search(kind, row.id)
      {:ok, receipt(:updated, kind, row)}
    end
  end

  # The row lock makes a stale write unexpected; if it happens, it is a failed
  # version guard like any other.
  defp update_row(changeset) do
    case Repo.update(changeset, stale_error_field: :edit_version) do
      {:error, %Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :edit_version),
          do: {:error, :conflict},
          else: {:error, changeset}

      updated ->
        updated
    end
  end

  defp write_search(:tip, id), do: Search.write_tip_text(id)
  defp write_search(:review, id), do: Search.write_review_text(id)

  defp receipt(outcome, kind, row) do
    %{
      outcome: outcome,
      kind: kind,
      id: row.id,
      tip_id: tip_id(row),
      edit_version: row.edit_version,
      state: state(row)
    }
  end

  defp edit_changeset(:tip, tip, params), do: Tip.edit_changeset(tip, params)
  defp edit_changeset(:review, review, params), do: Review.edit_changeset(review, params)

  defp tip_id(%Tip{id: id}), do: id
  defp tip_id(%Review{tip_id: id}), do: id

  defp state(%{dead_at: %DateTime{}}), do: :hidden
  defp state(_row), do: :live

  defp schema(:tip), do: Tip
  defp schema(:review), do: Review
end
