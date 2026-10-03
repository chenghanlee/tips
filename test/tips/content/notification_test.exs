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
end
