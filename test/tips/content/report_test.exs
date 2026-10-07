defmodule Tips.Content.ReportTest do
  use Tips.DataCase, async: true

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content
  alias Tips.Content.{Flag, Notification}

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.VisibilityFixtures

  for kind <- [:tip, :review] do
    test "#{kind}: one open report per reporter, kept as stored and changing nothing else" do
      kind = unquote(kind)
      target = target_fixture(kind)
      vote_fixture(target, %{user_id: target.user_id})
      target = Repo.reload!(target)
      reporter = Scope.for_user(user_fixture())
      detail = String.duplicate("é", 1000)

      assert {:ok, %{kind: ^kind, id: target_id, report_id: report_id, outcome: :stored}} =
               Content.report_content(reporter, kind, target.id, %{
                 reason: :fabricated,
                 detail: detail
               })

      assert target_id == target.id

      assert {:ok, %{report_id: ^report_id, outcome: :already_open}} =
               Content.report_content(reporter, kind, target.id, %{
                 "reason" => "spam",
                 "detail" => "A changed explanation."
               })

      assert [%Flag{id: ^report_id, reason: :fabricated, detail: ^detail, resolved_at: nil}] =
               Repo.all(Flag)

      # No hiding, version, counter, ranking or author change, and no notification.
      assert Repo.reload!(target) == target
      assert %User{ban: nil} = Repo.get!(User, target.user_id)
      assert Repo.all(Notification) == []

      Repo.update_all(Flag, set: [resolved_at: DateTime.utc_now(:second)])

      assert {:ok, %{report_id: new_id, outcome: :stored}} =
               Content.report_content(reporter, kind, target.id, %{reason: :spam})

      assert new_id != report_id
    end

    test "#{kind}: ineligible reporters and unreportable targets store nothing" do
      kind = unquote(kind)
      target = target_fixture(kind)
      attrs = %{reason: :spam}

      assert {:error, :unauthenticated} = Content.report_content(nil, kind, target.id, attrs)

      for {user, error} <- [
            {unconfirmed_user_fixture(), :unconfirmed},
            {full_ban!(user_fixture()), :forbidden},
            {delete_account!(user_fixture()), :unauthenticated}
          ] do
        assert {:error, ^error} =
                 Content.report_content(Scope.for_user(user), kind, target.id, attrs)
      end

      reporter = Scope.for_user(user_fixture())
      assert {:error, :not_found} = Content.report_content(reporter, kind, 9_000_000_000, attrs)
      assert {:error, :not_found} = Content.report_content(reporter, :user, target.id, attrs)

      for marker <- [:hidden, :deleted] do
        put_marker!(target, marker)
        assert {:error, :not_found} = Content.report_content(reporter, kind, target.id, attrs)
      end

      assert Repo.all(Flag) == []
    end
  end

  test "a report needs a policy reason and at most 1000 characters of explanation" do
    tip = tip_fixture()
    reporter = Scope.for_user(user_fixture())

    # 1001 characters as Postgres counts them, though only 501 graphemes.
    long = String.duplicate("é", 500) <> "x"

    for {attrs, field} <- [
          {%{detail: "No reason given."}, :reason},
          {%{reason: "disagree"}, :reason},
          {%{reason: :spam, detail: long}, :detail},
          {%{reason: :other, detail: "a\0b"}, :detail}
        ] do
      assert {:error, %Ecto.Changeset{errors: [{^field, _error}]}} =
               Content.report_content(reporter, :tip, tip.id, attrs)
    end

    assert {:ok, %{outcome: :stored}} =
             Content.report_content(reporter, :tip, tip.id, %{
               "reason" => "fabricated",
               "detail" => "  "
             })

    assert [%Flag{reason: :fabricated, detail: nil}] = Repo.all(Flag)
  end

  defp target_fixture(:tip), do: tip_fixture()
  defp target_fixture(:review), do: review_fixture()
end
