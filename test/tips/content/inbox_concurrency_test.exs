defmodule Tips.Content.InboxConcurrencyTest do
  # Committed transactions on separate backends. Opening the inbox captures
  # unread (id, count) pairs in one snapshot, then marks only rows still at the
  # captured count. A fold or new row that commits after the snapshot stays
  # unread, and read rows keep their time, count and order.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.LockSessions

  alias Tips.Accounts
  alias Tips.Accounts.User
  alias Tips.Content
  alias Tips.Content.{Notification, Tip}
  alias Tips.Repo

  setup do
    data =
      unboxed(fn ->
        {:ok, data} =
          Repo.transaction(fn ->
            recipient = user_fixture()
            voter = user_fixture()
            earlier = DateTime.add(DateTime.utc_now(:second), -3600)

            # The folded tip is the newest, the untouched one next.
            [folded_tip, untouched_tip, new_tip] = for _ <- 1..3, do: tip_fixture(recipient)

            folded = notify!(recipient, voter, folded_tip, DateTime.add(earlier, 2))
            untouched = notify!(recipient, voter, untouched_tip, DateTime.add(earlier, 1))

            %{
              recipient: recipient,
              voter: voter,
              folded: folded,
              untouched: untouched,
              new_tip: new_tip
            }
          end)

        data
      end)

    on_exit(fn -> unboxed(fn -> purge(data) end) end)
    Map.put(data, :supervisor, start_supervised!(Task.Supervisor))
  end

  test "a fold and a new row committed after the snapshot stay unread", data do
    ref = session(data.recipient)

    # The writer folds into one captured row and adds a new one, uncommitted:
    # the inbox snapshot cannot see either, and marking waits on the fold's lock.
    writer = open(data.supervisor)

    run(writer, fn ->
      :ok = fold(data, Repo.get!(Tip, data.folded.tip_id))
      :ok = fold(data, data.new_tip)
    end)

    inbox = call(data.supervisor, fn -> Content.get_inbox(ref, offset: 0, mark_read: true) end)
    await_blocked(inbox, writer)
    commit(writer)

    # The page is the snapshot from before the writer committed.
    assert {:ok, %{entries: entries}} = finish(inbox)
    assert ids(entries) == [data.folded.id, data.untouched.id]
    assert Enum.all?(entries, & &1.unread)

    unboxed(fn ->
      assert %{count: 2, read_at: nil} = Repo.reload!(data.folded)

      assert %{read_at: %DateTime{}} = untouched = Repo.reload!(data.untouched)
      assert {untouched.count, untouched.updated_at} == {1, data.untouched.updated_at}

      assert [%{count: 1, read_at: nil}] =
               Repo.all(from(n in Notification, where: n.tip_id == ^data.new_tip.id))

      # Opening again marks what arrived after the first visit.
      assert {:ok, %{entries: [%{unread: true}, %{unread: true}, %{unread: false}]}} =
               Content.get_inbox(ref, offset: 0, mark_read: true)

      assert Content.count_unread_notifications(Accounts.Scope.for_user(data.recipient)) == 0
    end)
  end

  defp notify!(recipient, actor, tip, updated_at) do
    Repo.insert!(%Notification{
      user_id: recipient.id,
      actor_id: actor.id,
      type: :tip_upvoted,
      tip_id: tip.id,
      updated_at: updated_at
    })
  end

  defp fold(data, tip), do: Notification.fold(:tip_upvoted, data.recipient.id, data.voter.id, tip)

  defp session(user) do
    unboxed(fn ->
      token = Accounts.generate_user_session_token(user)
      {:ok, _scope, ref, _inserted_at} = Accounts.get_scope_by_session_token(token)
      ref
    end)
  end

  defp ids(entries), do: Enum.map(entries, & &1.id)

  defp purge(data) do
    user_ids = [data.recipient.id, data.voter.id]
    Repo.delete_all(from(n in Notification, where: n.user_id in ^user_ids))
    Repo.delete_all(from(t in Tip, where: t.user_id in ^user_ids))
    Repo.delete_all(from(u in User, where: u.id in ^user_ids))
  end
end
