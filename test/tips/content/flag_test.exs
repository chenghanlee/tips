defmodule Tips.Content.FlagTest do
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  test "flags_reason_vals accepts fabricated and rejects wrong on insert and update" do
    reporter = user_fixture()
    tip = tip_fixture()
    now = DateTime.utc_now(:second)

    sql = """
    INSERT INTO flags (user_id, tip_id, reason, created_at)
    VALUES ($1, $2, $3, $4) RETURNING id
    """

    assert %{rows: [[id]]} = Repo.query!(sql, [reporter.id, tip.id, "fabricated", now])

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(sql, [reporter.id, tip.id, "wrong", now])
      end

    assert error.postgres.constraint == "flags_reason_vals"

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE flags SET reason = 'wrong' WHERE id = $1", [id])
      end

    assert error.postgres.constraint == "flags_reason_vals"
    assert %{rows: [["fabricated"]]} = Repo.query!("SELECT reason FROM flags WHERE id = $1", [id])
  end
end
