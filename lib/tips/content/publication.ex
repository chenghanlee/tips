defmodule Tips.Content.Publication do
  @moduledoc """
  Publishes new text tips and reviews and reconciles submission keys for
  `Tips.Content`.

  See "Publication" and "Transaction participants" in `Tips.Content`. A key
  lookup runs first and answers for an existing key without validation, write
  admission or eligibility. Only an absent key is admitted, validated and
  written: one transaction locks the author, then a review's live parent, then
  share-locks the selected curated choices while active, and inserts the
  content, its search text, its self-vote and a review's notification. Any
  rejection in the transaction rolls the attempt back; the key is then looked
  up again in a fresh statement before the rejection is returned.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Ecto.Changeset
  alias Tips.Accounts
  alias Tips.Accounts.{Scope, User}
  alias Tips.AdmissionLimiter

  alias Tips.Content.{
    Environment,
    Intent,
    Model,
    Notification,
    Review,
    Search,
    Tag,
    Tip,
    Visibility,
    Vote
  }

  alias Tips.Content.Media.Asset
  alias Tips.Repo

  require Logger

  @fields %{
    tip: [:title, :body, :tag_id, :model_id, :model_other, :environment_id, :prompt, :output],
    review: [:body, :model_id, :model_other, :environment_id, :prompt, :output]
  }

  # Curated choices a new write must select while active.
  @choices %{
    tip: [tag_id: Tag, model_id: Model, environment_id: Environment],
    review: [model_id: Model, environment_id: Environment]
  }

  @doc "See `Tips.Content.publish_tip/4` and `Tips.Content.publish_review/5`."
  @spec publish(
          Scope.t() | nil,
          Tips.Content.publication_kind(),
          term(),
          term(),
          term()
        ) ::
          {:ok, Tips.Content.publication_receipt()} | {:error, Tips.Content.publication_error()}
  def publish(scope, kind, submission_key, attrs, uploads) do
    intent = %{attrs: attrs, uploads: uploads}

    unknown_on_database_error(fn ->
      with {:ok, user} <- author(scope),
           {:ok, key} <- cast_key(kind, submission_key),
           nil <- find(scope, kind, key, intent),
           :ok <- admit(scope),
           {:ok, parent_id} <- parent_id(kind),
           {:ok, changeset} <- validate(kind, user, key, parent_id, attrs, uploads) do
        kind
        |> insert(user, parent_id, changeset)
        |> settle(scope, kind, key, intent)
      end
    end)
  end

  @doc "See `Tips.Content.get_publication/4`."
  @spec get(Scope.t() | nil, Tips.Content.publication_kind(), term(), term()) ::
          {:ok, Tips.Content.publication_receipt() | nil} | {:error, Tips.Content.lookup_error()}
  def get(scope, kind, submission_key, submitted_intent) do
    unknown_on_database_error(fn ->
      with {:ok, _user} <- author(scope),
           {:ok, key} <- uuid(submission_key),
           nil <- find(scope, kind, key, submitted_intent) do
        {:ok, nil}
      else
        :error -> {:ok, nil}
        result -> result
      end
    end)
  end

  defp author(%Scope{user: %User{id: id} = user}) when is_integer(id), do: {:ok, user}
  defp author(_scope), do: {:error, :unauthenticated}

  defp cast_key(kind, key) do
    case uuid(key) do
      {:ok, key} ->
        {:ok, key}

      :error ->
        {:error,
         kind |> schema() |> struct() |> change() |> add_error(:submission_key, "is invalid")}
    end
  end

  # The text form only; `Ecto.UUID.cast/1` would also take any 16-byte binary.
  defp uuid(key) when is_binary(key) and byte_size(key) == 36, do: Ecto.UUID.cast(key)
  defp uuid(_key), do: :error

  @doc false
  # Shared with `Tips.Content.Edit`: one write admission per attempt, never refunded.
  def admit(scope) do
    case AdmissionLimiter.check_write(scope) do
      :ok -> :ok
      {:error, {limit, _seconds}} = denied when limit in [:rate_limited, :capacity] -> denied
      {:error, :invalid_identity} -> {:error, :unauthenticated}
    end
  end

  defp parent_id(:tip), do: {:ok, nil}

  defp parent_id({:review, id}) when id in 1..9_223_372_036_854_775_807//1, do: {:ok, id}
  defp parent_id({:review, _id}), do: {:error, :not_found}

  ## Key lookup

  # The author's publication for `key`, or nil when none is committed now.
  defp find(%Scope{user: %User{id: user_id}} = scope, kind, key, intent) do
    query = from(c in schema(kind), where: c.user_id == ^user_id and c.submission_key == ^key)

    case {kind, Repo.one(query)} do
      {_kind, nil} ->
        nil

      {:tip, tip} ->
        {:ok, receipt(scope, :tip, tip, intent)}

      {{:review, tip_id}, %Review{tip_id: tip_id} = review} ->
        {:ok, receipt(scope, :review, review, intent)}

      {{:review, _tip_id}, %Review{}} ->
        {:error, :conflict}
    end
  end

  defp receipt(scope, kind, row, intent) do
    outcome =
      case Visibility.decision(scope, row) do
        :visible when not is_nil(intent) -> compare(kind, row, intent)
        _unreadable_or_identity_only -> :existing_unknown
      end

    receipt(outcome, kind, row)
  end

  defp receipt(outcome, kind, row) do
    %{
      outcome: outcome,
      kind: kind,
      id: row.id,
      tip_id: if(kind == :tip, do: row.id, else: row.tip_id),
      submission_key: row.submission_key,
      state: state(row)
    }
  end

  defp compare(kind, row, intent) do
    saved = %{attrs: Map.take(row, @fields[kind]), uploads: attachments(kind, row.id)}

    case Intent.compare(kind, saved, intent) do
      :equivalent -> :existing_equivalent
      :different -> :existing_different
      :unknown -> :existing_unknown
    end
  end

  # The saved selection in order, as an edit base holds it.
  defp attachments(kind, id) do
    parent = if kind == :tip, do: :tip_id, else: :review_id

    Repo.all(
      from(a in Asset,
        where: field(a, ^parent) == ^id and is_nil(a.cleanup_at) and not is_nil(a.position),
        order_by: a.position,
        select: {:retained, a.id, a.description}
      )
    )
  end

  defp state(%{deleted_at: %DateTime{}}), do: :deleted
  defp state(%{dead_at: %DateTime{}}), do: :hidden
  defp state(_row), do: :live

  ## New write

  defp validate(kind, user, key, parent_id, attrs, uploads) do
    kind = base_kind(kind)
    attrs = if is_map(attrs), do: attrs, else: %{}

    params =
      attrs
      |> Map.take(@fields[kind])
      |> Map.merge(%{submission_key: key, tip_id: parent_id})

    changeset =
      kind
      |> content_changeset(user, params)
      |> validate_intent(@fields[kind], attrs)
      |> validate_uploads(uploads)

    if changeset.valid?, do: {:ok, changeset}, else: {:error, %{changeset | action: :insert}}
  end

  defp content_changeset(:tip, user, params),
    do: Tip.changeset(%Tip{user_id: user.id}, Map.delete(params, :tip_id))

  defp content_changeset(:review, user, params),
    do: Review.changeset(%Review{user_id: user.id}, params)

  defp validate_intent(changeset, fields, attrs) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      if Map.has_key?(attrs, field),
        do: changeset,
        else: add_error(changeset, field, "is missing", validation: :intent)
    end)
  end

  # Text publication accepts only an empty selection. Errors keep selection order.
  defp validate_uploads(changeset, uploads) when is_list(uploads) do
    uploads
    |> Enum.reverse()
    |> Enum.reduce(changeset, fn upload, changeset ->
      {message, keys} = upload_error(upload)
      add_error(changeset, :uploads, message, keys)
    end)
  end

  defp validate_uploads(changeset, _uploads), do: add_error(changeset, :uploads, "is invalid")

  defp upload_error({:missing_image, slot}), do: {"must be selected again", slot: slot}

  defp upload_error({:retained, media_id, _description}),
    do: {"cannot be kept in a new publication", media_id: media_id}

  defp upload_error({:staged_video, media_id}), do: {"is not supported yet", media_id: media_id}

  defp upload_error({:image_file, slot, _file, _description}),
    do: {"is not supported yet", slot: slot}

  defp upload_error(_malformed), do: {"is invalid", []}

  defp insert(kind, user, parent_id, changeset) do
    Repo.transact(fn ->
      with :ok <- lock_author(user.id),
           {:ok, parent_author_id} <- lock_parent(parent_id),
           :ok <- lock_choices(changeset, base_kind(kind)),
           {:ok, row} <- Repo.insert(changeset),
           :ok <- write_dependents(base_kind(kind), row, parent_author_id) do
        {:ok, row}
      end
    end)
  end

  @doc false
  # Shared with `Tips.Content.Edit`: locks the participating account first.
  def lock_author(id) do
    case Repo.one(from(u in User, where: u.id == ^id, lock: "FOR NO KEY UPDATE")) do
      nil -> {:error, :unauthenticated}
      user -> Accounts.check_eligibility(user, :contribute)
    end
  end

  # After a wait, the lock rechecks the live markers on the parent's newest version.
  defp lock_parent(nil), do: {:ok, nil}

  defp lock_parent(tip_id) do
    query =
      from(t in Tip,
        where: t.id == ^tip_id and is_nil(t.deleted_at) and is_nil(t.dead_at),
        lock: "FOR NO KEY UPDATE",
        select: t.user_id
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      author_id -> {:ok, author_id}
    end
  end

  defp lock_choices(changeset, kind) do
    with {:error, changeset} <- lock_active_choices(changeset, kind),
         do: {:error, %{changeset | action: :insert}}
  end

  @doc false
  # After the account and content locks. A share lock holds each newly selected
  # choice active until commit; a retirement that commits first fails the
  # recheck. Only changes are checked, so an edit keeps a retired saved choice.
  # Unknown ids reach the foreign keys, which the changesets map to errors.
  def lock_active_choices(changeset, kind) do
    changeset =
      Enum.reduce(@choices[kind], changeset, fn {field, schema}, changeset ->
        with id when is_binary(id) <- get_change(changeset, field),
             false <-
               Repo.one(
                 from(c in schema, where: c.id == ^id, lock: "FOR SHARE", select: c.active)
               ) do
          add_error(changeset, field, "is not available")
        else
          _absent_unknown_or_active -> changeset
        end
      end)

    if changeset.valid?, do: :ok, else: {:error, changeset}
  end

  defp write_dependents(:tip, tip, nil) do
    with :ok <- Search.write_tip_text(tip.id) do
      Repo.insert!(%Vote{user_id: tip.user_id, tip_id: tip.id, value: 1})
      :ok
    end
  end

  defp write_dependents(:review, review, parent_author_id) do
    with :ok <- Search.write_review_text(review.id) do
      Repo.insert!(%Vote{user_id: review.user_id, review_id: review.id, value: 1})
      :ok = Notification.fold(:tip_reviewed, parent_author_id, review.user_id, review)
    end
  end

  defp settle({:ok, row}, _scope, kind, _key, _intent),
    do: {:ok, receipt(:created, base_kind(kind), row)}

  # The attempt rolled back. It may have waited on the author lock while a
  # same-key winner committed, so a fresh statement reads the key first.
  defp settle({:error, reason}, scope, kind, key, intent) do
    case find(scope, kind, key, intent) do
      nil -> rejection(reason)
      found -> found
    end
  end

  defp rejection(%Changeset{} = changeset) do
    cond do
      one_review_conflict?(changeset) -> {:error, :already_reviewed}
      key_conflict?(changeset) -> {:error, :outcome_unknown}
      true -> {:error, changeset}
    end
  end

  defp rejection(reason), do: {:error, reason}

  defp key_conflict?(changeset),
    do:
      Enum.any?(changeset.errors, fn {_field, {_message, keys}} ->
        keys[:constraint] == :unique
      end)

  defp one_review_conflict?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, keys}} ->
      keys[:constraint_name] == "reviews_one_per_user"
    end)
  end

  defp base_kind(:tip), do: :tip
  defp base_kind({:review, _tip_id}), do: :review
  defp base_kind(:review), do: :review

  defp schema(kind), do: if(base_kind(kind) == :tip, do: Tip, else: Review)

  # A database error or lost connection leaves the outcome unknown, never absent or rejected.
  defp unknown_on_database_error(fun) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error("Publication outcome unknown: #{database_reason(error)}")
      {:error, :outcome_unknown}
  end

  # Postgres details can quote submitted values; log only the code and message.
  defp database_reason(%Postgrex.Error{postgres: %{code: code, message: message}}),
    do: "#{code}: #{message}"

  defp database_reason(error), do: Exception.message(error)
end
