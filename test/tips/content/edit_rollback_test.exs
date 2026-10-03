defmodule Tips.Content.EditRollbackTest do
  # Each test injects a database failure with a raising trigger created inside its own
  # sandbox transaction, so the DDL rolls back with the test. Trigger DDL locks the
  # table until then, so this module runs alone. The failure is a confirmed rollback;
  # Content cannot tell it from a lost commit, so both report an unknown outcome.
  use Tips.DataCase, async: false

  import ExUnit.CaptureLog
  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  alias Tips.Accounts.Scope
  alias Tips.Content
  alias Tips.Content.{Review, Tip}

  @attrs %{
    tip: %{
      title: "Pin the dependency first",
      body: "Pin the version before asking for an upgrade plan.",
      tag_id: "workflow",
      model_id: nil,
      model_other: nil,
      environment_id: nil,
      prompt: nil,
      output: nil
    },
    review: %{
      body: "The pinned plan worked.",
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

  for {kind, table} <- [
        tip: "tips",
        tip: "tip_search",
        review: "reviews",
        review: "review_search"
      ] do
    test "edit failing at #{table} rolls back and keeps the expected version" do
      kind = unquote(kind)
      {scope, row} = published(kind)
      search = search_row(kind, row.id)
      changed = %{@attrs[kind] | body: "A changed searchable body."}
      fail_writes_to(unquote(table))

      log =
        capture_log(fn ->
          assert {:error, :outcome_unknown} = edit(scope, kind, row.id, 1, changed)
        end)

      assert log =~ "injected edit failure"
      assert Repo.reload!(row) == row
      assert search_row(kind, row.id) == search

      # Nothing committed: the author reloads, keeps the input and retries at the same version.
      stop_failing(unquote(table))
      assert {:ok, %{edit_version: 1}} = Content.get_edit_form(scope, kind, row.id)
      assert {:ok, %{outcome: :updated, edit_version: 2}} = edit(scope, kind, row.id, 1, changed)
    end
  end

  defp published(:tip) do
    scope = Scope.for_user(user_fixture())
    {:ok, %{id: id}} = Content.publish_tip(scope, Ecto.UUID.generate(), @attrs.tip, [])
    {scope, Repo.get!(Tip, id)}
  end

  defp published(:review) do
    scope = Scope.for_user(user_fixture())
    key = Ecto.UUID.generate()
    {:ok, %{id: id}} = Content.publish_review(scope, tip_fixture().id, key, @attrs.review, [])
    {scope, Repo.get!(Review, id)}
  end

  defp edit(scope, :tip, id, version, attrs), do: Content.edit_tip(scope, id, version, attrs, [])

  defp edit(scope, :review, id, version, attrs),
    do: Content.edit_review(scope, id, version, attrs, [])

  defp search_row(kind, id) do
    Repo.query!(
      "SELECT search_text, text_at, embedding IS NOT NULL, embed_after FROM #{kind}_search WHERE #{kind}_id = $1",
      [id]
    ).rows
  end

  defp fail_writes_to(table) do
    Repo.query!(
      "CREATE TRIGGER edit_test_fail BEFORE INSERT OR UPDATE ON #{table} " <>
        "FOR EACH ROW EXECUTE FUNCTION edit_test_fail()"
    )
  end

  defp stop_failing(table), do: Repo.query!("DROP TRIGGER edit_test_fail ON #{table}")
end
