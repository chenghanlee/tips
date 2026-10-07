defmodule Tips.Content.VoteConcurrencyTest do
  # Committed transactions on separate backends. A vote locks the voter, then
  # only its direct target; a hide, author deletion or full ban that holds one of
  # those locks decides eligibility before the vote writes.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.LockSessions
  import Tips.VisibilityFixtures

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content
  alias Tips.Content.{Notification, Review, Tip, Vote}
  alias Tips.Repo

  setup do
    data =
      unboxed(fn ->
        # One transaction, so a failed setup leaves no committed rows behind.
        {:ok, data} =
          Repo.transaction(fn ->
            author = user_fixture()
            tip = tip_fixture(author)

            review =
              Repo.insert!(%Review{
                tip_id: tip.id,
                user_id: author.id,
                submission_key: Ecto.UUID.generate(),
                body: "The technique helped in this synthetic test."
              })

            %{
              author: author,
              voter: user_fixture(),
              moderator: moderator!(user_fixture()),
              tip: tip,
              review: review
            }
          end)

        data
      end)

    on_exit(fn -> unboxed(fn -> purge(data) end) end)
    Map.put(data, :supervisor, start_supervised!(Task.Supervisor))
  end

  test "a review vote does not wait for its parent tip", data do
    holder = open(data.supervisor)
    assert [_id] = run(holder, fn -> lock_row(Tip, data.tip.id) end)

    assert {:ok, %{vote: 1, up_count: 1, outcome: :changed}} =
             finish(call(data.supervisor, fn -> vote(data, :review, 1) end))

    commit(holder)
  end

  for kind <- [:tip, :review], race <- [:hide, :delete, :full_ban] do
    test "a #{kind} vote waiting on a committed #{race} is rejected", data do
      kind = unquote(kind)
      race = unquote(race)

      holder = open(data.supervisor)
      run(holder, fn -> commit_side(race, kind, data) end)

      call = call(data.supervisor, fn -> vote(data, kind, 1) end)
      await_blocked(call, holder)
      commit(holder)

      assert finish(call) == {:error, expected_error(race)}

      unboxed(fn ->
        assert Repo.all(from(v in Vote, where: v.user_id == ^data.voter.id)) == []
        assert %{up_count: 0} = Repo.get!(schema(kind), Map.fetch!(data, kind).id)
        assert Repo.all(from(n in Notification, where: n.user_id == ^data.author.id)) == []
      end)
    end
  end

  defp commit_side(:hide, kind, data),
    do:
      {:ok, _} =
        Content.hide_content(
          Scope.for_user(data.moderator),
          kind,
          Map.fetch!(data, kind).id,
          1,
          []
        )

  defp commit_side(:delete, kind, data),
    do:
      {:ok, _} =
        Content.delete_content(Scope.for_user(data.author), kind, Map.fetch!(data, kind).id)

  defp commit_side(:full_ban, _kind, data), do: full_ban!(data.voter)

  defp expected_error(:full_ban), do: :forbidden
  defp expected_error(_race), do: :not_found

  defp vote(data, kind, value),
    do: Content.set_vote(Scope.for_user(data.voter), kind, Map.fetch!(data, kind).id, value)

  defp schema(:tip), do: Tip
  defp schema(:review), do: Review

  defp lock_row(schema, id),
    do: Repo.all(from(c in schema, where: c.id == ^id, lock: "FOR NO KEY UPDATE", select: c.id))

  defp purge(data) do
    user_ids = [data.author.id, data.voter.id, data.moderator.id]

    Repo.delete_all(from(n in Notification, where: n.user_id in ^user_ids))
    Repo.delete_all(from(v in Vote, where: v.user_id in ^user_ids))
    Repo.delete_all(from(f in Tips.Content.Flag, where: f.tip_id == ^data.tip.id))
    Repo.delete_all(from(s in "review_search", where: s.review_id == ^data.review.id))
    Repo.delete_all(from(s in "tip_search", where: s.tip_id == ^data.tip.id))
    Repo.delete_all(from(r in Review, where: r.id == ^data.review.id))
    Repo.delete_all(from(t in Tip, where: t.id == ^data.tip.id))
    Repo.delete_all(from(u in User, where: u.id in ^user_ids))
  end
end
