defmodule Tips.Content.NotificationTest do
  use Tips.DataCase, async: true

  alias Tips.Content.Notification

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.ModerationFixtures

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

  defp fold!(recipient, actor, review) do
    {:ok, :ok} =
      Repo.transaction(fn -> Notification.fold(:tip_reviewed, recipient.id, actor.id, review) end)
  end
end
