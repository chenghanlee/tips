defmodule Tips.Content.NotificationTest do
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  test "notifications_type_vals accepts tip_reviewed and rejects wrong on insert and update" do
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
        Repo.query!(sql, [recipient.id, review.id, "wrong", now])
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
