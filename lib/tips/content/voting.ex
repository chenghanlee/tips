defmodule Tips.Content.Voting do
  @moduledoc """
  Desired-state votes on a tip or review for `Tips.Content`.

  See "Voting" in `Tips.Content`. One transaction locks the voter's account, then
  only the voted tip or review, never a review's parent. Every writer of an
  account's votes holds that account's lock, so the stored vote read under it is
  current: the request either matches it (`:unchanged`, no write) or changes it
  once. The counter trigger updates the locked target, and the receipt reads
  those counters before commit.
  """

  import Ecto.Query

  alias Tips.Accounts.Scope
  alias Tips.Content.{Deletion, Notification, Publication, Review, Tip, Vote}
  alias Tips.Repo

  require Logger

  @doc "See `Tips.Content.set_vote/4`."
  @spec set(Scope.t() | nil, term(), term(), Tips.Content.vote()) ::
          {:ok, Tips.Content.vote_receipt()} | {:error, Tips.Content.vote_error()}
  def set(scope, kind, id, desired) do
    unknown_on_database_error(fn ->
      with {:ok, user} <- Deletion.actor(scope),
           :ok <- Publication.admit(scope),
           {:ok, kind} <- Deletion.kind(kind),
           {:ok, id} <- Deletion.write_id(id) do
        save(kind, user.id, id, desired)
      end
    end)
  end

  defp save(kind, user_id, id, desired) do
    Repo.transact(fn ->
      with :ok <- Deletion.lock_account(user_id, :contribute),
           {:ok, target} <- lock_live(kind, id) do
        outcome = write(target, user_id, current(target, user_id), desired)
        {:ok, receipt(kind, target, desired, outcome)}
      end
    end)
  end

  # Hidden and deleted content takes no vote changes, as its capabilities say.
  defp lock_live(kind, id) do
    case Deletion.lock_one(Deletion.schema(kind), id) do
      {:ok, %{deleted_at: nil, dead_at: nil} = target} -> {:ok, target}
      {:ok, _not_live} -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp current(target, user_id), do: Repo.one(votes(target, user_id) |> select([v], v.value))

  defp write(_target, _user_id, desired, desired), do: :unchanged

  defp write(target, user_id, _current, nil) do
    {1, _} = Repo.delete_all(votes(target, user_id))
    :changed
  end

  defp write(target, user_id, nil, desired) do
    Repo.insert!(struct!(Vote, [user_id: user_id, value: desired] ++ target_key(target)))
    notify(target, user_id, desired)
  end

  defp write(target, user_id, _current, desired) do
    {1, _} = Repo.update_all(votes(target, user_id), set: [value: desired])
    notify(target, user_id, desired)
  end

  # Each change to Helpful is one helpful-vote event; the fold skips the author.
  defp notify(target, user_id, 1) do
    :ok = Notification.fold(upvoted(target), target.user_id, user_id, target)
    :changed
  end

  defp notify(_target, _user_id, -1), do: :changed

  defp receipt(kind, target, vote, outcome) do
    counters =
      Repo.one!(
        from(c in Deletion.schema(kind),
          where: c.id == ^target.id,
          select: map(c, [:up_count, :down_count, :score])
        )
      )

    Map.merge(counters, %{kind: kind, id: target.id, vote: vote, outcome: outcome})
  end

  defp votes(%Tip{id: id}, user_id), do: where(Vote, user_id: ^user_id, tip_id: ^id)
  defp votes(%Review{id: id}, user_id), do: where(Vote, user_id: ^user_id, review_id: ^id)

  defp target_key(%Tip{id: id}), do: [tip_id: id]
  defp target_key(%Review{id: id}), do: [review_id: id]

  defp upvoted(%Tip{}), do: :tip_upvoted
  defp upvoted(%Review{}), do: :review_upvoted

  # A database error or lost connection leaves the outcome unknown, never rejected.
  defp unknown_on_database_error(fun) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error("Vote outcome unknown: #{database_reason(error)}")
      {:error, :outcome_unknown}
  end

  # Postgres details can quote stored values; log only the code and message.
  defp database_reason(%Postgrex.Error{postgres: %{code: code, message: message}}),
    do: "#{code}: #{message}"

  defp database_reason(error), do: Exception.message(error)
end
