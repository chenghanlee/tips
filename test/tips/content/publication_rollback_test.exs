defmodule Tips.Content.PublicationRollbackTest do
  # Each test injects a database failure with a raising trigger created inside its own
  # sandbox transaction, so the DDL rolls back with the test. Trigger DDL locks the
  # table until then, so this module runs alone.
  use Tips.DataCase, async: false

  import ExUnit.CaptureLog
  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  alias Tips.Accounts.Scope
  alias Tips.Content
  alias Tips.Content.{Notification, Review, Tip, Vote}

  @tip_attrs %{
    title: "Pin the dependency first",
    body: "Pin the version before asking for an upgrade plan.",
    tag_id: "workflow",
    model_id: nil,
    model_other: nil,
    environment_id: nil,
    prompt: nil,
    output: nil
  }

  @review_attrs %{
    body: "The pinned plan worked.",
    model_id: nil,
    model_other: nil,
    environment_id: nil,
    prompt: nil,
    output: nil
  }

  setup do
    Repo.query!("""
    CREATE FUNCTION publication_test_fail() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'injected publication failure'; END $$
    """)

    :ok
  end

  describe "required dependent write failure rolls back the whole publication" do
    for table <- ["tip_search", "votes"] do
      test "tip failing at #{table}" do
        fail_inserts_into(unquote(table))
        scope = Scope.for_user(user_fixture())
        key = Ecto.UUID.generate()

        assert_outcome_unknown(fn -> Content.publish_tip(scope, key, @tip_attrs, []) end)

        assert Repo.all(Tip) == []
        assert Repo.all(Vote) == []
        assert Repo.aggregate("tip_search", :count) == 0
        assert {:ok, nil} = Content.get_publication(scope, :tip, key, nil)

        # Nothing committed, so the same key may publish once the failure is gone.
        stop_failing(unquote(table))
        assert {:ok, %{outcome: :created}} = Content.publish_tip(scope, key, @tip_attrs, [])
      end
    end

    for table <- ["review_search", "votes", "notifications"] do
      test "review failing at #{table}" do
        parent = tip_fixture()
        fail_inserts_into(unquote(table))
        scope = Scope.for_user(user_fixture())
        key = Ecto.UUID.generate()

        assert_outcome_unknown(fn ->
          Content.publish_review(scope, parent.id, key, @review_attrs, [])
        end)

        assert Repo.all(Review) == []
        assert Repo.all(Vote) == []
        assert Repo.all(Notification) == []
        assert Repo.aggregate("review_search", :count) == 0
        assert %Tip{review_count: 0, up_count: 0, down_count: 0} = Repo.reload!(parent)
        assert {:ok, nil} = Content.get_publication(scope, {:review, parent.id}, key, nil)
      end
    end
  end

  defp fail_inserts_into(table) do
    Repo.query!(
      "CREATE TRIGGER publication_test_fail BEFORE INSERT ON #{table} " <>
        "FOR EACH ROW EXECUTE FUNCTION publication_test_fail()"
    )
  end

  defp stop_failing(table), do: Repo.query!("DROP TRIGGER publication_test_fail ON #{table}")

  defp assert_outcome_unknown(publish) do
    log = capture_log(fn -> assert {:error, :outcome_unknown} = publish.() end)
    assert log =~ "injected publication failure"
  end
end
