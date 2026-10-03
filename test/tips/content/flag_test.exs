defmodule Tips.Content.FlagTest do
  use Tips.DataCase, async: true

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
end
