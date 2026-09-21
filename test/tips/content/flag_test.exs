defmodule Tips.Content.FlagTest do
  use Tips.DataCase, async: true

  alias Tips.Content.Flag

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.ModerationFixtures

  describe "open reports" do
    test "flags_open_tip permits one open flag per reporter and tip" do
      reporter = user_fixture()
      tip = tip_fixture()
      original = flag_fixture(reporter, %{tip_id: tip.id})

      assert_raise Ecto.ConstraintError, ~r/flags_open_tip/, fn ->
        flag_fixture(reporter, %{tip_id: tip.id})
      end

      original =
        original
        |> change(resolved_at: DateTime.utc_now(:second))
        |> Repo.update!()

      replacement = flag_fixture(reporter, %{tip_id: tip.id})

      assert_raise Ecto.ConstraintError, ~r/flags_open_tip/, fn ->
        original
        |> change(resolved_at: nil)
        |> Repo.update!()
      end

      assert flag_fixture(user_fixture(), %{tip_id: tip.id}).id
      assert flag_fixture(reporter).id
      assert replacement.id
    end

    test "flags_open_review permits one open flag per reporter and review" do
      reporter = user_fixture()
      review = review_fixture()
      original = flag_fixture(reporter, %{review_id: review.id})

      assert_raise Ecto.ConstraintError, ~r/flags_open_review/, fn ->
        flag_fixture(reporter, %{review_id: review.id})
      end

      original =
        original
        |> change(resolved_at: DateTime.utc_now(:second))
        |> Repo.update!()

      replacement = flag_fixture(reporter, %{review_id: review.id})

      assert_raise Ecto.ConstraintError, ~r/flags_open_review/, fn ->
        original
        |> change(resolved_at: nil)
        |> Repo.update!()
      end

      assert flag_fixture(user_fixture(), %{review_id: review.id}).id
      assert flag_fixture(reporter, %{review_id: review_fixture().id}).id
      assert replacement.id
    end
  end

  describe "database checks" do
    test "flags_one_target rejects neither and both targets on insert and update" do
      assert_raise Ecto.ConstraintError, ~r/flags_one_target/, fn ->
        flag_fixture(user_fixture(), %{tip_id: nil})
      end

      assert_raise Ecto.ConstraintError, ~r/flags_one_target/, fn ->
        flag_fixture(user_fixture(), %{tip_id: tip_fixture().id, review_id: review_fixture().id})
      end

      flag = flag_fixture(user_fixture(), %{review_id: review_fixture().id})

      assert_raise Ecto.ConstraintError, ~r/flags_one_target/, fn ->
        flag
        |> change(review_id: nil)
        |> Repo.update!()
      end

      assert Repo.reload!(flag).review_id
    end

    test "flags_reason_vals accepts the enum and rejects wrong on insert and update" do
      assert Ecto.Enum.values(Flag, :reason) == [:spam, :harmful, :fabricated, :other]

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
          Repo.query!(sql, [reporter.id, tip_fixture().id, "wrong", now])
        end

      assert error.postgres.constraint == "flags_reason_vals"

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("UPDATE flags SET reason = 'wrong' WHERE id = $1", [id])
        end

      assert error.postgres.constraint == "flags_reason_vals"

      assert %{rows: [["fabricated"]]} =
               Repo.query!("SELECT reason FROM flags WHERE id = $1", [id])
    end

    test "flags_detail_chk accepts null, empty, and 1000 code points but rejects 1001" do
      at_limit = String.duplicate("e\u0301", 500)
      over_limit = at_limit <> "\u0301"

      assert flag_fixture(user_fixture(), %{detail: nil}).id
      assert flag_fixture(user_fixture(), %{detail: ""}).id
      flag = flag_fixture(user_fixture(), %{detail: at_limit})

      assert_raise Ecto.ConstraintError, ~r/flags_detail_chk/, fn ->
        flag_fixture(user_fixture(), %{detail: over_limit})
      end

      assert_raise Ecto.ConstraintError, ~r/flags_detail_chk/, fn ->
        flag
        |> change(detail: over_limit)
        |> Repo.update!()
      end

      assert Repo.reload!(flag).detail == at_limit
    end
  end

  describe "foreign keys" do
    for {field, value} <- [user_id: -1, tip_id: -1, review_id: -1, resolved_by: -1] do
      test "flags_#{field}_fkey rejects an unknown reference" do
        attrs = %{unquote(field) => unquote(value), reason: :fabricated}

        assert_raise Ecto.ConstraintError, ~r/flags_#{unquote(field)}_fkey/, fn ->
          flag_fixture(user_fixture(), attrs)
        end
      end
    end
  end

  test "flag indexes have the designed keys, uniqueness, and predicates" do
    assert index_definition("flags_open_tip") ==
             "CREATE UNIQUE INDEX flags_open_tip ON public.flags USING btree (user_id, tip_id) WHERE ((tip_id IS NOT NULL) AND (resolved_at IS NULL))"

    assert index_definition("flags_open_review") ==
             "CREATE UNIQUE INDEX flags_open_review ON public.flags USING btree (user_id, review_id) WHERE ((review_id IS NOT NULL) AND (resolved_at IS NULL))"

    assert index_definition("flags_open") ==
             "CREATE INDEX flags_open ON public.flags USING btree (created_at, id) WHERE (resolved_at IS NULL)"
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
