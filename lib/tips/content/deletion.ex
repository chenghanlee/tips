defmodule Tips.Content.Deletion do
  @moduledoc """
  Author deletion of a tip or review for `Tips.Content`, and the lock order it
  shares with moderator liveness changes.

  See "Deletion and moderation" in `Tips.Content`. One transaction locks the
  acting account, then the tip, then the review, then writes the dependents
  and finally the content row. A review always locks its parent tip first,
  whatever the parent's state, because the review-count trigger writes it.
  """

  import Ecto.Query

  alias Tips.Accounts
  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.{Flag, Notification, Publication, Review, Tip}
  alias Tips.Content.Media.Asset
  alias Tips.Repo

  require Logger

  # Positive bigint ids; anything else cannot name a row.
  @row_ids 1..9_223_372_036_854_775_807

  @doc "See `Tips.Content.delete_content/3`."
  @spec delete(Scope.t() | nil, term(), term()) ::
          {:ok, Tips.Content.lifecycle_receipt()} | {:error, Tips.Content.delete_error()}
  def delete(scope, kind, id) do
    unknown_on_database_error(fn ->
      with {:ok, user} <- actor(scope),
           :ok <- Publication.admit(scope),
           {:ok, kind} <- kind(kind),
           {:ok, id} <- write_id(id),
           {:ok, {outcome, row}} <- delete_owned(kind, user.id, id) do
        {:ok, receipt(kind, row, outcome)}
      end
    end)
  end

  defp delete_owned(kind, user_id, id) do
    Repo.transact(fn ->
      with :ok <- lock_account(user_id, :delete_own_content),
           {:ok, row} <- lock_target(kind, id),
           :ok <- owned(row, user_id) do
        delete_row(kind, row)
      end
    end)
  end

  # Another author's row is indistinguishable from a missing one.
  defp owned(%{user_id: user_id}, user_id), do: :ok
  defp owned(_row, _user_id), do: {:error, :not_found}

  defp delete_row(_kind, %{deleted_at: %DateTime{}} = row), do: {:ok, {:unchanged, row}}

  defp delete_row(kind, row) do
    if attached_media?(kind, row.id) do
      {:error, :media_cleanup_required}
    else
      # Dependents first, then the row itself; any failure rolls all of them back.
      resolve_flags(kind, row.id)
      delete_notifications(kind, row.id)
      {:ok, {:changed, update_row!(kind, row.id, set: [deleted_at: now()])}}
    end
  end

  # Until media cleanup is transactional, deletion refuses rows with media of their own.
  defp attached_media?(kind, id),
    do:
      Repo.exists?(from(a in Asset, where: field(a, ^key(kind)) == ^id and is_nil(a.cleanup_at)))

  defp resolve_flags(kind, id) do
    Repo.update_all(
      from(f in Flag, where: field(f, ^key(kind)) == ^id and is_nil(f.resolved_at)),
      set: [resolved_at: now(), resolved_by: nil]
    )
  end

  defp delete_notifications(:review, id),
    do: Repo.delete_all(from(n in Notification, where: n.review_id == ^id))

  # Review-upvote notifications belong to the reviews, which stay.
  defp delete_notifications(:tip, id) do
    reviews = from(r in Review, where: r.tip_id == ^id, select: r.id)

    Repo.delete_all(
      from(n in Notification,
        where: n.tip_id == ^id or (n.type == :tip_reviewed and n.review_id in subquery(reviews))
      )
    )
  end

  ## Shared with Tips.Content.Moderation and Tips.Content.Voting

  @doc false
  # Locks the acting account and checks its current eligibility for `operation`.
  def lock_account(user_id, operation) do
    case Repo.one(from(u in User, where: u.id == ^user_id, lock: "FOR NO KEY UPDATE")) do
      nil -> {:error, :unauthenticated}
      user -> Accounts.check_eligibility(user, operation)
    end
  end

  @doc false
  # Locks the target's tip, then the review. The parent id is immutable, so it is
  # read before locking; the review is rechecked once its own lock is held.
  def lock_target(:tip, id), do: lock_one(Tip, id)

  def lock_target(:review, id) do
    case Repo.one(from(r in Review, where: r.id == ^id, select: r.tip_id)) do
      nil ->
        {:error, :not_found}

      tip_id ->
        {:ok, _tip} = lock_one(Tip, tip_id)
        lock_one(Review, id)
    end
  end

  @doc false
  # Locks one tip or review row, without its parent; votes lock only their target.
  def lock_one(schema, id) do
    case Repo.one(from(c in schema, where: c.id == ^id, lock: "FOR NO KEY UPDATE")) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  @doc false
  # Writes the locked row and advances its version once. Counter triggers follow.
  def update_row!(kind, id, set: changes) do
    {1, [row]} =
      Repo.update_all(
        from(c in schema(kind), where: c.id == ^id, select: c),
        set: changes,
        inc: [edit_version: 1]
      )

    row
  end

  @doc false
  def receipt(kind, row, outcome) do
    %{
      kind: kind,
      id: row.id,
      tip_id: tip_id(row),
      state: state(row),
      edit_version: row.edit_version,
      outcome: outcome
    }
  end

  @doc false
  def state(%{deleted_at: %DateTime{}}), do: :deleted
  def state(%{dead_at: %DateTime{}}), do: :hidden
  def state(_row), do: :live

  @doc false
  def actor(%Scope{user: %User{id: id} = user}) when is_integer(id), do: {:ok, user}
  def actor(_scope), do: {:error, :unauthenticated}

  @doc false
  def kind(kind) when kind in [:tip, :review], do: {:ok, kind}
  def kind(_kind), do: {:error, :not_found}

  @doc false
  def write_id(id) when is_integer(id) and id in @row_ids, do: {:ok, id}
  def write_id(_id), do: {:error, :not_found}

  @doc false
  def key(:tip), do: :tip_id
  def key(:review), do: :review_id

  @doc false
  def schema(:tip), do: Tip
  def schema(:review), do: Review

  @doc false
  def tip_id(%Tip{id: id}), do: id
  def tip_id(%Review{tip_id: id}), do: id

  defp now, do: DateTime.utc_now(:second)

  # A database error or lost connection leaves the outcome unknown, never rejected.
  defp unknown_on_database_error(fun) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error("Deletion outcome unknown: #{database_reason(error)}")
      {:error, :outcome_unknown}
  end

  # Postgres details can quote stored values; log only the code and message.
  defp database_reason(%Postgrex.Error{postgres: %{code: code, message: message}}),
    do: "#{code}: #{message}"

  defp database_reason(error), do: Exception.message(error)
end
