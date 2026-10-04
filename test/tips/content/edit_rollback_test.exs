defmodule Tips.Content.EditRollbackTest do
  # Each test injects a database failure with a raising trigger created inside its own
  # sandbox transaction, so the DDL rolls back with the test. Trigger DDL locks the
  # table until then, so this module runs alone. A raising trigger proves rollback and
  # error mapping, not a lost COMMIT reply.
  use Tips.DataCase, async: false

  import ExUnit.CaptureLog
  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  alias Tips.Accounts.Scope
  alias Tips.Content

  @attrs %{
    tip: %{
      title: "Search fails",
      body: "The search write raises.",
      tag_id: "workflow",
      model_id: nil,
      model_other: nil,
      environment_id: nil,
      prompt: nil,
      output: nil
    },
    review: %{
      body: "The search write raises.",
      model_id: nil,
      model_other: nil,
      environment_id: nil,
      prompt: nil,
      output: nil
    }
  }

  setup do
    Repo.query!("""
    CREATE FUNCTION edit_test_fail() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'injected edit failure'; END $$
    """)

    :ok
  end

  for {kind, table} <- [tip: "tip_search", review: "review_search"] do
    test "#{kind}: search failure rolls back the version and returns outcome_unknown" do
      kind = unquote(kind)
      author = user_fixture()
      row = content(kind, author)

      Repo.query!(
        "CREATE TRIGGER edit_test_fail BEFORE INSERT OR UPDATE ON #{unquote(table)} " <>
          "FOR EACH ROW EXECUTE FUNCTION edit_test_fail()"
      )

      log =
        capture_log(fn ->
          assert {:error, :outcome_unknown} = edit(kind, author, row.id, @attrs[kind])
        end)

      assert log =~ "injected edit failure"
      assert Repo.reload!(row) == row
      assert Repo.aggregate(unquote(table), :count) == 0

      # Nothing committed, so the same expected version saves once the failure is gone.
      Repo.query!("DROP TRIGGER edit_test_fail ON #{unquote(table)}")

      assert {:ok, %{outcome: :updated, edit_version: 2}} =
               edit(kind, author, row.id, @attrs[kind])
    end
  end

  defp content(:tip, author), do: tip_fixture(author)
  defp content(:review, author), do: review_fixture(tip_fixture(), %{user_id: author.id})

  defp edit(:tip, author, id, attrs),
    do: Content.edit_tip(Scope.for_user(author), id, 1, attrs, [])

  defp edit(:review, author, id, attrs),
    do: Content.edit_review(Scope.for_user(author), id, 1, attrs, [])
end
