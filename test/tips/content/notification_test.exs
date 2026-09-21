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
    test "notifications_one_target rejects neither and both targets on insert and update" do
      assert_raise Ecto.ConstraintError, ~r/notifications_one_target/, fn ->
        notification_fixture(user_fixture(), %{type: :review_upvoted, review_id: nil})
      end

      assert_raise Ecto.ConstraintError, ~r/notifications_one_target/, fn ->
        notification_fixture(user_fixture(), %{
          tip_id: tip_fixture().id,
          review_id: review_fixture().id
        })
      end

      notification =
        notification_fixture(user_fixture(), %{
          type: :review_upvoted,
          review_id: review_fixture().id
        })

      assert_raise Ecto.ConstraintError, ~r/notifications_one_target/, fn ->
        notification
        |> change(review_id: nil)
        |> Repo.update!()
      end

      assert Repo.reload!(notification).review_id
    end

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

    test "notifications_count_chk accepts one and rejects zero and negative values on insert and update" do
      notification = notification_fixture(user_fixture(), %{count: 1})

      for count <- [0, -1] do
        assert_raise Ecto.ConstraintError, ~r/notifications_count_chk/, fn ->
          notification_fixture(user_fixture(), %{count: count})
        end
      end

      assert_raise Ecto.ConstraintError, ~r/notifications_count_chk/, fn ->
        notification
        |> change(count: 0)
        |> Repo.update!()
      end

      assert Repo.reload!(notification).count == 1
    end

    test "notifications_type_vals accepts the enum and rejects wrong on insert and update" do
      assert Ecto.Enum.values(Notification, :type) == [
               :tip_upvoted,
               :review_upvoted,
               :tip_reviewed
             ]

      recipient = user_fixture()
      review = review_fixture()
      now = DateTime.utc_now(:second)

      sql = """
      INSERT INTO notifications (user_id, review_id, type, updated_at)
      VALUES ($1, $2, $3, $4) RETURNING id, count
      """

      assert %{rows: [[id, 1]]} = Repo.query!(sql, [recipient.id, review.id, "tip_reviewed", now])

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(sql, [recipient.id, review_fixture().id, "wrong", now])
        end

      assert error.postgres.constraint == "notifications_type_vals"

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("UPDATE notifications SET type = 'wrong' WHERE id = $1", [id])
        end

      assert error.postgres.constraint == "notifications_type_vals"

      assert %{rows: [["tip_reviewed"]]} =
               Repo.query!("SELECT type FROM notifications WHERE id = $1", [id])
    end
  end

  describe "foreign keys" do
    for {field, value, attrs} <- [
          {:user_id, -1, %{}},
          {:actor_id, -1, %{}},
          {:tip_id, -1, %{}},
          {:review_id, -1, %{type: :tip_reviewed}}
        ] do
      test "notifications_#{field}_fkey rejects an unknown reference" do
        attrs = Map.put(unquote(Macro.escape(attrs)), unquote(field), unquote(value))

        assert_raise Ecto.ConstraintError, ~r/notifications_#{unquote(field)}_fkey/, fn ->
          notification_fixture(user_fixture(), attrs)
        end
      end
    end

    test "actor_id may be null" do
      assert %{actor_id: nil} = notification_fixture(user_fixture(), %{actor_id: nil})
    end
  end

  test "notification indexes have the designed keys, order, null behavior, and predicates" do
    assert index_definition("notifications_fold") ==
             "CREATE UNIQUE INDEX notifications_fold ON public.notifications USING btree (user_id, type, tip_id, review_id) NULLS NOT DISTINCT WHERE (read_at IS NULL)"

    assert index_definition("notifications_inbox") ==
             "CREATE INDEX notifications_inbox ON public.notifications USING btree (user_id, updated_at DESC, id DESC)"

    assert index_definition("notifications_by_tip") ==
             "CREATE INDEX notifications_by_tip ON public.notifications USING btree (tip_id) WHERE (tip_id IS NOT NULL)"

    assert index_definition("notifications_by_review") ==
             "CREATE INDEX notifications_by_review ON public.notifications USING btree (review_id) WHERE (review_id IS NOT NULL)"
  end

  defp index_definition(name) do
    assert %{rows: [[definition]]} =
             Repo.query!(
               "SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' AND indexname = $1",
               [name]
             )

    definition
  end
end
