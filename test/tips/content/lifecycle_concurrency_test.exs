defmodule Tips.Content.LifecycleConcurrencyTest do
  # A bulk transaction's content phase holds the parent tip on its own backend,
  # sharing no account lock with the real operation. While the operation waits
  # for that tip, the holder must still take the review at once: an operation
  # that locked the review before its parent would make that probe fail.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.LockSessions
  import Tips.VisibilityFixtures

  alias Tips.Accounts.Scope
  alias Tips.Content
  alias Tips.Content.{Review, Tip}
  alias Tips.Repo

  for operation <- [:delete, :hide, :restore], parent <- [:live, :deleted] do
    test "#{operation} under a #{parent} parent: single-review liveness serializes with ordered bulk locks" do
      operation = unquote(operation)
      data = setup_rows(operation, unquote(parent))

      holder = open(data.supervisor)
      assert [_id] = run(holder, fn -> lock_tip(data.tip.id) end)

      call = call(data.supervisor, fn -> perform(operation, data) end)
      await_blocked(call, holder)

      assert [_id] = run(holder, fn -> lock_review_nowait(data.review.id) end)
      commit(holder)

      assert {:ok, %{outcome: :changed, state: state}} = finish(call)

      unboxed(fn ->
        review = Repo.get!(Review, data.review.id)
        tip = Repo.get!(Tip, data.tip.id)
        assert state == expected_state(operation)
        assert {review.deleted_at != nil, review.dead_at != nil} == markers(operation)

        live =
          Repo.aggregate(
            from(r in Review,
              where: r.tip_id == ^tip.id and is_nil(r.deleted_at) and is_nil(r.dead_at)
            ),
            :count
          )

        assert tip.review_count == live
        assert live == live_after(operation)
      end)
    end
  end

  defp setup_rows(operation, parent) do
    supervisor = start_supervised!(Task.Supervisor)

    {author, moderator, tip, review} =
      unboxed(fn ->
        author = user_fixture()
        tip = tip_fixture(user_fixture())

        review =
          Repo.insert!(%Review{
            tip_id: tip.id,
            user_id: author.id,
            submission_key: Ecto.UUID.generate(),
            body: "The technique helped in this synthetic test.",
            created_at: DateTime.utc_now(:second)
          })

        if parent == :deleted, do: put_marker!(tip, :deleted)

        review =
          if operation == :restore do
            {1, _} =
              Repo.update_all(where(Review, id: ^review.id),
                set: [dead_at: DateTime.utc_now(:second)],
                inc: [edit_version: 1]
              )

            Repo.get!(Review, review.id)
          else
            review
          end

        {author, moderator!(user_fixture()), tip, review}
      end)

    on_exit(fn -> unboxed(fn -> purge([author.id, moderator.id, tip.user_id]) end) end)

    %{
      author: author,
      moderator: moderator,
      tip: tip,
      review: review,
      supervisor: supervisor
    }
  end

  defp perform(:delete, data),
    do: Content.delete_content(Scope.for_user(data.author), :review, data.review.id)

  defp perform(:hide, data),
    do: Content.hide_content(Scope.for_user(data.moderator), :review, data.review.id, 1, [])

  defp perform(:restore, data),
    do: Content.restore_content(Scope.for_user(data.moderator), :review, data.review.id, 2, [])

  defp expected_state(:delete), do: :deleted
  defp expected_state(:hide), do: :hidden
  defp expected_state(:restore), do: :live

  defp live_after(:restore), do: 1
  defp live_after(_operation), do: 0

  defp markers(:delete), do: {true, false}
  defp markers(:hide), do: {false, true}
  defp markers(:restore), do: {false, false}

  defp lock_tip(id),
    do: Repo.all(from(t in Tip, where: t.id == ^id, lock: "FOR NO KEY UPDATE", select: t.id))

  defp lock_review_nowait(id),
    do:
      Repo.all(
        from(r in Review, where: r.id == ^id, lock: "FOR NO KEY UPDATE NOWAIT", select: r.id)
      )

  defp purge(user_ids) do
    tip_ids = Repo.all(from(t in Tip, where: t.user_id in ^user_ids, select: t.id))

    review_ids =
      Repo.all(
        from(r in Review, where: r.user_id in ^user_ids or r.tip_id in ^tip_ids, select: r.id)
      )

    Repo.delete_all(from(s in "review_search", where: s.review_id in ^review_ids))
    Repo.delete_all(from(s in "tip_search", where: s.tip_id in ^tip_ids))
    Repo.delete_all(from(r in Review, where: r.id in ^review_ids))
    Repo.delete_all(from(t in Tip, where: t.id in ^tip_ids))
    Repo.delete_all(from(u in Tips.Accounts.User, where: u.id in ^user_ids))
  end
end
