defmodule Tips.Content.BrowseTest do
  use Tips.DataCase, async: true

  alias Tips.Accounts.Scope
  alias Tips.Content
  alias Tips.Content.Browse

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.VisibilityFixtures

  setup do
    %{author: user_fixture()}
  end

  test "Hot and New order live tips with id tie-breaks; deleted and hidden tips never show",
       %{author: author} do
    now = DateTime.utc_now(:second)
    two_days_ago = DateTime.add(now, -2, :day)

    # log10(1000) = 3 outweighs two days of age (0.5) in the hot score.
    popular = tip_fixture(author, %{title: "Popular", up_count: 1000, created_at: two_days_ago})

    [tied_first, tied_second] =
      for n <- 1..2, do: tip_fixture(author, %{title: "Tied #{n}", created_at: now})

    for marker <- [:hidden, :deleted, :deleted_and_hidden] do
      author |> tip_fixture(%{title: "Gone #{marker}"}) |> put_marker!(marker)
    end

    moderator = moderator!(user_fixture())

    for scope <- [nil, Scope.for_user(author), Scope.for_user(moderator)] do
      assert {:ok, %{entries: hot, has_more: false}} = Content.list_tips(scope, sort: :hot)
      assert ids(hot) == [popular.id, tied_second.id, tied_first.id]

      assert {:ok, %{entries: new}} = Content.list_tips(scope, sort: :new)
      assert ids(new) == [tied_second.id, tied_first.id, popular.id]
    end
  end

  test "filters match the tip author's setup exactly and combine with AND", %{author: author} do
    match =
      tip_fixture(author, %{tag_id: "workflow", model_id: "claude", environment_id: "cli"})

    other_environment =
      tip_fixture(author, %{tag_id: "workflow", model_id: "claude", environment_id: "chat"})

    free_text = tip_fixture(author, %{tag_id: "workflow", model_other: "claude"})
    reviewed = tip_fixture(author, %{tag_id: "workflow", model_id: "gpt", environment_id: "cli"})
    review_fixture(reviewed, %{model_id: "claude", environment_id: "cli"})

    filters = [tag_id: "workflow", model_id: "claude", environment_id: "cli"]
    assert {:ok, %{entries: entries}} = Content.list_tips(nil, filters)
    assert ids(entries) == [match.id]

    assert {:ok, %{entries: entries}} = Content.list_tips(nil, model_id: "claude")
    assert Enum.sort(ids(entries)) == Enum.sort([match.id, other_environment.id])

    assert {:ok, %{entries: entries}} = Content.list_tips(nil, tag_id: "workflow")

    assert Enum.sort(ids(entries)) ==
             Enum.sort([match.id, other_environment.id, free_text.id, reviewed.id])
  end

  test "pages hold twenty rows and use a one-row lookahead for Next", %{author: author} do
    created = for _n <- 1..41, do: tip_fixture(author)
    newest_first = created |> Enum.map(& &1.id) |> Enum.sort(:desc)

    assert {:ok, %{entries: first, has_more: true}} = Content.list_tips(nil, sort: :new)
    assert {:ok, %{entries: second, has_more: true}} = Content.list_tips(nil, offset: 20)
    assert {:ok, %{entries: [last], has_more: false}} = Content.list_tips(nil, offset: 40)
    assert {:ok, %{entries: [], has_more: false}} = Content.list_tips(nil, offset: 60)

    assert ids(first) ++ ids(second) ++ [last.id] == newest_first
  end

  test "rows are text summaries with the viewer's vote", %{author: author} do
    tip = tip_fixture(author, %{title: "Voted", model_other: "local-qwen"})
    viewer = user_fixture()
    vote_fixture(tip, %{user_id: viewer.id, value: -1})

    assert {:ok, %{entries: [summary]}} = Content.list_tips(Scope.for_user(viewer), [])

    assert %{
             state: :visible,
             title: "Voted",
             slug: "voted",
             tag: %{id: "other", label: "Other technique"},
             model: %{id: nil, label: "local-qwen"},
             author: %{handle: handle},
             viewer_vote: -1,
             capabilities: %{vote: true}
           } = summary

    assert handle == author.handle
    refute Map.has_key?(summary, :body)
    assert {:ok, %{entries: [%{viewer_vote: nil}]}} = Content.list_tips(nil, [])
  end

  test "invalid options are rejected" do
    for opts <- [
          [sort: :top],
          [offset: -20],
          [offset: 7],
          [tag_id: 1],
          [page: 2],
          [sort: :new, sort: :hot],
          :hot
        ] do
      assert Content.list_tips(nil, opts) == {:error, :invalid_option}, inspect(opts)
    end
  end

  # An unset filter must add no predicate, not `(param IS NULL OR column =
  # param)`, so each sort and the tag filter can walk their partial index.
  test "unset filters add no predicate and each order reads its index", %{author: author} do
    tip_fixture(author, %{tag_id: "workflow"})
    Repo.query!("SET LOCAL enable_seqscan = off")
    Repo.query!("SET LOCAL enable_sort = off")

    for {opts, index} <- [
          {[sort: :hot], "tips_hot"},
          {[sort: :new], "tips_new"},
          {[sort: :hot, tag_id: "workflow"], "tips_hot_by_tag"},
          {[sort: :new, tag_id: "workflow"], "tips_new_by_tag"}
        ] do
      {sql, params} = Repo.to_sql(:all, Browse.query(opts))
      %{rows: [[[plan]]]} = Repo.query!("EXPLAIN (FORMAT JSON) " <> sql, params)
      assert index in indexes(plan["Plan"]), inspect({opts, plan})
      refute sql =~ ~r/\bOR\b/i, sql
    end
  end

  defp ids(entries), do: Enum.map(entries, & &1.id)

  defp indexes(%{} = node) do
    own = if index = node["Index Name"], do: [index], else: []
    own ++ Enum.flat_map(Map.get(node, "Plans", []), &indexes/1)
  end
end
