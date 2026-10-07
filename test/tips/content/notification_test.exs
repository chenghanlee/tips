defmodule Tips.Content.NotificationTest do
  use Tips.DataCase, async: true

  # The inbox snapshot declares this level; the sandbox transaction must match.
  @moduletag isolation: "REPEATABLE READ"

  alias Tips.Accounts
  alias Tips.Accounts.Scope
  alias Tips.Content
  alias Tips.Content.Notification

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.ModerationFixtures
  import Tips.VisibilityFixtures

  describe "unread folding" do
    test "notifications_fold permits one unread fold for a tip target" do
      recipient = user_fixture()
      tip = tip_fixture()
      original = notification_fixture(recipient, %{tip_id: tip.id})

      assert_raise Ecto.ConstraintError, ~r/notifications_fold/, fn ->
        notification_fixture(recipient, %{tip_id: tip.id})
      end

      original =
        original
        |> change(read_at: DateTime.utc_now(:second))
        |> Repo.update!()

      replacement = notification_fixture(recipient, %{tip_id: tip.id})

      assert_raise Ecto.ConstraintError, ~r/notifications_fold/, fn ->
        original
        |> change(read_at: nil)
        |> Repo.update!()
      end

      replacement
      |> change(read_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert Repo.aggregate(Notification, :count) == 2
    end

    test "notifications_fold treats a null tip target as equal for review folds" do
      recipient = user_fixture()
      review = review_fixture()

      notification_fixture(recipient, %{type: :tip_reviewed, review_id: review.id})

      assert_raise Ecto.ConstraintError, ~r/notifications_fold/, fn ->
        notification_fixture(recipient, %{type: :tip_reviewed, review_id: review.id})
      end
    end

    test "unread folds separate recipients, types, and targets" do
      recipient = user_fixture()
      tip = tip_fixture()
      other_tip = tip_fixture()
      review = review_fixture()

      assert notification_fixture(recipient, %{tip_id: tip.id}).id
      assert notification_fixture(user_fixture(), %{tip_id: tip.id}).id
      assert notification_fixture(recipient, %{tip_id: other_tip.id}).id
      assert notification_fixture(recipient, %{type: :review_upvoted, review_id: review.id}).id
      assert notification_fixture(recipient, %{type: :tip_reviewed, review_id: review.id}).id
    end
  end

  describe "review fold helper" do
    test "review fold sets initial timestamp and refreshes unread row" do
      recipient = user_fixture()
      review = review_fixture()
      first_actor = user_fixture()
      second_actor = user_fixture()

      fold!(recipient, first_actor, review)

      assert [%Notification{count: 1, read_at: nil, updated_at: %DateTime{}} = row] =
               Repo.all(Notification)

      assert %{type: :tip_reviewed, tip_id: nil} = row
      assert row.actor_id == first_actor.id and row.review_id == review.id

      earlier = DateTime.add(DateTime.utc_now(:second), -3600)
      row |> change(updated_at: earlier) |> Repo.update!()
      fold!(recipient, second_actor, review)

      assert [%Notification{id: id, count: 2, read_at: nil} = folded] = Repo.all(Notification)
      assert id == row.id and folded.actor_id == second_actor.id
      assert DateTime.after?(folded.updated_at, earlier)
    end

    test "a read row stays read and the next fold starts a new unread row" do
      recipient = user_fixture()
      review = review_fixture()

      fold!(recipient, user_fixture(), review)
      read_at = DateTime.utc_now(:second)
      [read] = Repo.all(Notification)
      read |> change(read_at: read_at) |> Repo.update!()

      fold!(recipient, user_fixture(), review)

      assert [%Notification{count: 1, read_at: ^read_at}, %Notification{count: 1, read_at: nil}] =
               Repo.all(from(n in Notification, order_by: n.id))
    end

    test "self actions write nothing and a rollback discards the fold" do
      recipient = user_fixture()
      review = review_fixture()

      fold!(recipient, recipient, review)

      assert {:error, :rolled_back} =
               Repo.transaction(fn ->
                 :ok = Notification.fold(:tip_reviewed, recipient.id, user_fixture().id, review)
                 Repo.rollback(:rolled_back)
               end)

      assert Repo.all(Notification) == []

      assert_raise ArgumentError, ~r/caller transaction/, fn ->
        Notification.fold(:tip_reviewed, recipient.id, user_fixture().id, review)
      end
    end
  end

  describe "database checks" do
    test "notifications_type_target accepts only the target for each type on insert and update" do
      tip = tip_fixture()
      review = review_fixture()

      assert notification_fixture(user_fixture(), %{type: :tip_upvoted, tip_id: tip.id}).id

      assert notification_fixture(user_fixture(), %{type: :review_upvoted, review_id: review.id}).id

      assert notification_fixture(user_fixture(), %{type: :tip_reviewed, review_id: review.id}).id

      assert_raise Ecto.ConstraintError, ~r/notifications_type_target/, fn ->
        notification_fixture(user_fixture(), %{type: :tip_upvoted, review_id: review.id})
      end

      assert_raise Ecto.ConstraintError, ~r/notifications_type_target/, fn ->
        notification_fixture(user_fixture(), %{type: :review_upvoted, tip_id: tip.id})
      end

      assert_raise Ecto.ConstraintError, ~r/notifications_type_target/, fn ->
        notification_fixture(user_fixture(), %{type: :tip_reviewed, tip_id: tip.id})
      end

      notification = notification_fixture(user_fixture(), %{tip_id: tip_fixture().id})

      assert_raise Ecto.ConstraintError, ~r/notifications_type_target/, fn ->
        notification
        |> change(type: :review_upvoted)
        |> Repo.update!()
      end

      assert Repo.reload!(notification).type == :tip_upvoted
    end
  end

  describe "inbox" do
    test "pages newest first, twenty rows with lookahead, and reads without marking" do
      recipient = user_fixture()
      start = DateTime.add(DateTime.utc_now(:second), -3600)

      # Pairs of rows share a timestamp, so the id breaks the tie.
      rows =
        for i <- 1..22,
            do: notification_fixture(recipient, %{updated_at: DateTime.add(start, div(i, 2))})

      newest_first =
        rows |> Enum.sort_by(&{DateTime.to_unix(&1.updated_at), &1.id}, :desc) |> ids()

      assert {:ok, %{entries: first, has_more: true}} =
               Content.get_inbox(session(recipient), offset: 0)

      assert {:ok, %{entries: second, has_more: false}} =
               Content.get_inbox(session(recipient), offset: 20)

      assert ids(first ++ second) == newest_first
      assert Enum.all?(first ++ second, & &1.unread)
      assert unread_ids(recipient) == Enum.sort(ids(rows))
    end

    test "marking reads every captured row of this account and keeps time, count and order" do
      recipient = user_fixture()
      other = user_fixture()
      start = DateTime.add(DateTime.utc_now(:second), -3600)

      rows =
        for i <- 1..25 do
          notification_fixture(recipient, %{updated_at: DateTime.add(start, i), count: i})
        end

      already_read =
        notification_fixture(recipient, %{updated_at: start, read_at: DateTime.add(start, 1)})

      others = notification_fixture(other)

      # Page 2 loads five captured rows; marking also covers the twenty on page 1.
      assert {:ok, %{entries: page, has_more: false}} =
               Content.get_inbox(session(recipient), offset: 20, mark_read: true)

      # The page renders the snapshot it captured.
      assert Enum.map(page, & &1.unread) == [true, true, true, true, true, false]

      assert unread_ids(recipient) == []
      assert unread_ids(other) == [others.id]
      assert Repo.reload!(already_read).read_at == already_read.read_at

      for row <- rows do
        assert %{count: count, updated_at: updated_at, read_at: %DateTime{}} = Repo.reload!(row)
        assert {count, updated_at} == {row.count, row.updated_at}
      end

      assert {:ok, %{entries: entries}} = Content.get_inbox(session(recipient), offset: 0)
      assert ids(entries) == rows |> Enum.reverse() |> Enum.take(20) |> ids()
      refute Enum.any?(entries, & &1.unread)
    end

    test "targets come from the deletion-first projection" do
      recipient = user_fixture()
      reviewer = user_fixture()

      own_hidden = put_marker!(tip_fixture(recipient, %{title: "Own hidden"}), :hidden)
      deleted = put_marker!(tip_fixture(recipient, %{title: "Secret deleted"}), :deleted)
      other_hidden = put_marker!(tip_fixture(user_fixture(), %{title: "Secret hidden"}), :hidden)
      own_review = review_fixture(other_hidden, %{user_id: recipient.id})
      own_tip = tip_fixture(recipient, %{title: "Own live"})
      visible_review = review_fixture(own_tip, %{user_id: reviewer.id})
      hidden_review = put_marker!(review_fixture(own_hidden), :hidden)

      notification_fixture(recipient, %{tip_id: own_hidden.id})
      notification_fixture(recipient, %{tip_id: deleted.id})
      notification_fixture(recipient, %{type: :review_upvoted, review_id: own_review.id})

      for review <- [visible_review, hidden_review] do
        notification_fixture(recipient, %{
          type: :tip_reviewed,
          review_id: review.id,
          actor_id: review.user_id
        })
      end

      assert {:ok, %{entries: entries}} = Content.get_inbox(session(recipient), offset: 0)
      by_target = Map.new(entries, &{{&1.type, &1.review_id || &1.tip.id}, &1})

      assert %{tip: %{state: :visible, title: "Own hidden"}, actor: nil} =
               by_target[{:tip_upvoted, own_hidden.id}]

      assert %{tip: %{state: :deleted, title: "Deleted tip", slug: "deleted-tip"}} =
               by_target[{:tip_upvoted, deleted.id}]

      assert %{tip: %{state: :removed, title: "Removed tip", id: other_hidden_id}} =
               by_target[{:review_upvoted, own_review.id}]

      assert other_hidden_id == other_hidden.id

      assert %{tip: %{title: "Own live"}, actor: %{handle: handle}} =
               by_target[{:tip_reviewed, visible_review.id}]

      assert handle == reviewer.handle

      # The recipient may not read the hidden review, so its author stays unnamed.
      assert %{tip: %{title: "Own hidden"}, actor: nil} =
               by_target[{:tip_reviewed, hidden_review.id}]

      refute inspect(entries) =~ "Secret"
    end

    test "rejects a malformed page and an unadmitted viewer" do
      ref = session(user_fixture())

      for opts <- [[offset: -20], [offset: 7], [offset: "0"], [mark_read: :yes], [sort: :new]] do
        assert Content.get_inbox(ref, opts) == {:error, :invalid_option}, inspect(opts)
      end

      assert Content.get_inbox(nil, offset: 0) == {:error, :unauthenticated}
    end

    test "the badge counts unread rows up to 100" do
      recipient = user_fixture()
      scope = Scope.for_user(recipient)
      assert Content.count_unread_notifications(scope) == 0

      notification_fixture(recipient, %{read_at: DateTime.utc_now(:second)})
      notification_fixture(user_fixture())
      author = user_fixture()
      tips = for _ <- 1..101, do: tip_fixture(author)

      for tip <- Enum.take(tips, 3), do: notification_fixture(recipient, %{tip_id: tip.id})
      assert Content.count_unread_notifications(scope) == 3

      for tip <- Enum.drop(tips, 3), do: notification_fixture(recipient, %{tip_id: tip.id})
      assert Content.count_unread_notifications(scope) == 100
    end
  end

  defp session(user) do
    token = Accounts.generate_user_session_token(user)
    {:ok, _scope, ref, _inserted_at} = Accounts.get_scope_by_session_token(token)
    ref
  end

  defp unread_ids(user) do
    Repo.all(
      from(n in Notification,
        where: n.user_id == ^user.id and is_nil(n.read_at),
        order_by: n.id,
        select: n.id
      )
    )
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  defp fold!(recipient, actor, review) do
    {:ok, :ok} =
      Repo.transaction(fn -> Notification.fold(:tip_reviewed, recipient.id, actor.id, review) end)
  end
end
