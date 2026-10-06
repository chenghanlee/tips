defmodule Tips.Content.SearchTest do
  # BM25 corpus statistics include other sandbox transactions. Ranking assertions
  # need a fixed corpus, so run after concurrent fixture writers have finished.
  use Tips.DataCase, async: false

  alias Tips.Accounts.Scope
  alias Tips.Content
  alias Tips.Content.{Model, Review, Search, Tip}
  alias Tips.Content.Search.{Embeddings, ProviderCapacity}

  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  import Tips.SearchFixtures,
    only: [provider_inputs: 0, respond_vector: 3, search_row: 1, stub_provider: 1]

  import Tips.VisibilityFixtures

  @dimensions 1024

  setup do
    %{author: user_fixture()}
  end

  describe "lexical retrieval" do
    test "lexical nonmatches never enter ranks under sequential and index plans", ctx do
      strong = tip!(ctx, title: "Quokka quokka quokka")
      reviewed = tip!(ctx, title: "Parent without the animal")

      weak =
        tip!(ctx, title: "One quokka among many other unrelated words in a much longer title")

      review = review!(reviewed, body: "Quokka quokka")
      nonmatching = for _ <- 1..3, do: tip!(ctx, title: "Unrelated plain tip")
      review!(hd(nonmatching), body: "Nothing relevant here")

      for plan <- [:index, :sequential] do
        in_plan(plan, fn ->
          assert {:ok, %{candidates: candidates, total: 3}} = Search.rank("quokka", [])
          # Tip and review scores come from separate BM25 indexes, so only the
          # tips' own order is fixed.
          assert [{strong_id, nil} | rest] = Enum.map(candidates, &{&1.tip_id, &1.review_id})
          assert strong_id == strong.id
          assert Enum.sort(rest) == Enum.sort([{reviewed.id, review.id}, {weak.id, nil}])

          scans = scans(explain("quokka", []))

          case plan do
            :index ->
              assert {"Index Scan", "tips_bm25"} in scans
              assert {"Index Scan", "reviews_bm25"} in scans

            :sequential ->
              assert {"Seq Scan", "tip_search"} in scans
              assert {"Seq Scan", "review_search"} in scans
              refute Enum.any?(scans, fn {_node, name} -> name =~ "bm25" end)
          end

          for query <- ["wombat", "the and of", "\"\""] do
            assert {:ok, %{candidates: [], total: 0}} = Search.rank(query, [])
          end
        end)
      end

      # Standalone scoring gives nonmatching documents zero, not a negative score.
      for tip <- nonmatching do
        assert lexical_score(:tip, tip.id, "quokka") == 0
      end

      assert lexical_score(:tip, strong.id, "quokka") < 0
      assert lexical_score(:review, review.id, "quokka") < 0
    end

    test "quotes operators and pasted errors are ordinary search text", ctx do
      error_tip =
        tip!(ctx, title: "Debugging tip", output: ~s(ERROR: column "user_id" does not exist))

      chart_tip = tip!(ctx, title: "Bar charts in reports")
      prefix_tip = tip!(ctx, title: "Quokkaland travel notes")

      assert ids(search!(nil, ~s(ERROR:  column "user_id" does not exist))) == [error_tip.id]
      assert ids(search!(nil, ~s("user_id))) == [error_tip.id]
      assert ids(search!(nil, ~s('user_id' \\ exist))) == [error_tip.id]
      assert ids(search!(nil, "chart & !bar")) == [chart_tip.id]
      assert ids(search!(nil, "reports | (zzz)")) == [chart_tip.id]
      assert ids(search!(nil, "quokka:*")) == []
      assert ids(search!(nil, "column\u0000user_id")) == [error_tip.id]
      assert ids(search!(nil, "'; DROP TABLE accounts; --")) == []
      assert Repo.get!(Tip, prefix_tip.id)
    end
  end

  describe "filters" do
    test "every branch applies filters to the parent tip", ctx do
      parent = [tag_id: "persona", model_id: "gpt", environment_id: "chat"]
      reviewer = [model_id: "claude", environment_id: "cli"]

      matched = branch_tips(ctx, parent, reviewer)

      decoys =
        branch_tips(ctx, [tag_id: "phrase", model_id: "claude", environment_id: "cli"],
          model_id: "gpt",
          environment_id: "chat"
        )

      matched_ids = Enum.sort(Map.values(matched))
      decoy_ids = Enum.sort(Map.values(decoys))
      hybrid = [embedding: query_vector()]

      assert sorted_ids(search!(nil, "zebra", hybrid)) == Enum.sort(matched_ids ++ decoy_ids)

      for {filters, expected} <- [
            {[model_id: "gpt"], matched_ids},
            {[model_id: "claude"], decoy_ids},
            {[environment_id: "chat"], matched_ids},
            {[environment_id: "cli"], decoy_ids},
            {[tag_id: "persona"], matched_ids},
            {[tag_id: "phrase"], decoy_ids},
            {[tag_id: "persona", model_id: "gpt", environment_id: "chat"], matched_ids},
            {[tag_id: "persona", model_id: "claude"], []},
            {[model_id: "gemini"], []}
          ] do
        assert sorted_ids(search!(nil, "zebra", hybrid ++ filters)) == expected,
               "filters #{inspect(filters)}"
      end

      # Keyword-only retrieval keeps the same parent predicates in its two branches.
      assert sorted_ids(search!(nil, "zebra", model_id: "gpt")) ==
               Enum.sort([matched.tips_bm25, matched.reviews_bm25])

      assert sorted_ids(search!(nil, "zebra", model_id: "claude")) ==
               Enum.sort([decoys.tips_bm25, decoys.reviews_bm25])
    end

    test "filters accept only active curated choices", ctx do
      Repo.insert!(%Model{id: "retired", label: "Retired model", sort_order: 99, active: false})
      retired = tip!(ctx, title: "Zebra on a retired model", model_id: "retired")

      assert ids(search!(nil, "zebra")) == [retired.id]

      assert [%{tip: %{model: %{id: "retired", label: "Retired model"}}}] =
               entries(search!(nil, "zebra"))

      for opts <- [
            [model_id: "retired"],
            [model_id: "unknown"],
            [tag_id: "unknown"],
            [environment_id: "unknown"],
            [model_id: 1],
            [tag_id: nil]
          ] do
        assert Search.search(nil, "zebra", opts) == {:error, :invalid_filter}, inspect(opts)
      end
    end
  end

  describe "validation" do
    test "invalid input fails before retrieval" do
      cases = [
        {"", [], :blank_query},
        {" \t\n ", [], :blank_query},
        {"\u0000", [], :blank_query},
        {nil, [], :invalid_query},
        {<<0xFF>>, [], :invalid_query},
        {"zebra", [offset: -20], :invalid_offset},
        {"zebra", [offset: 5], :invalid_offset},
        {"zebra", [offset: 200], :invalid_offset},
        {"zebra", [offset: "20"], :invalid_offset},
        {"zebra", [offset: 20.0], :invalid_offset},
        {"zebra", [embedding: List.duplicate(0.0, @dimensions)], :invalid_embedding},
        # Nonzero as a double, zero once pgvector stores it as float32.
        {"zebra", [embedding: [1.0e-100 | List.duplicate(0.0, @dimensions - 1)]],
         :invalid_embedding},
        {"zebra", [embedding: [4.0e38 | List.duplicate(0.0, @dimensions - 1)]],
         :invalid_embedding},
        {"zebra", [embedding: List.duplicate(1.0, @dimensions - 1)], :invalid_embedding},
        {"zebra", [embedding: [:nan | List.duplicate(1.0, @dimensions - 1)]], :invalid_embedding},
        {"zebra", [embedding: "[1,0]"], :invalid_embedding},
        {"zebra", [page: 2], :invalid_option},
        {"zebra", :not_a_list, :invalid_option}
      ]

      for {query, opts, reason} <- cases do
        assert {{:error, ^reason}, 0} = count_queries(fn -> Search.search(nil, query, opts) end),
               inspect({query, opts})
      end

      stub_provider(&respond_vector(&1, &2, query_vector()))

      for {query, opts, reason} <- [
            {" \t\n ", [], :blank_query},
            {String.duplicate("é", 513), [], :query_too_long},
            {"zebra", [embedding: query_vector()], :invalid_option}
          ] do
        assert {{:error, ^reason}, 0} =
                 count_queries(fn -> Content.search_tips(nil, query, opts) end),
               inspect({query, opts})
      end

      assert provider_inputs() == []
    end

    test "embedding magnitude never changes vector ranking", ctx do
      # The orthogonal tip is older, so collapsed distances would rank it first.
      far = tip!(ctx, title: "Plain far", vector: plane(1.0, -1.0))
      near = tip!(ctx, title: "Plain near", vector: plane(-1.0, -1.0))

      # The smallest float32 subnormal, a subnormal, ordinary, mixed and float32 max.
      queries = [
        {-1.0e-45, -1.0e-45},
        {-1.0e-40, -1.0e-40},
        {-1, -1},
        {-3.0e38, -2.9e38},
        {-3.402_823_466_385_288_6e38, -3.402_823_466_385_288_6e38}
      ]

      # The exact plan checks the encoded direction. Approximate HNSW scans can
      # miss rows; the filtered recall test covers them.
      in_plan(:sequential, fn ->
        for {x, y} <- queries do
          assert ids(search!(nil, "unmatched", embedding: plane(x, y))) == [near.id, far.id],
                 "query #{inspect({x, y})}"
        end
      end)
    end
  end

  describe "search requests" do
    setup do
      test = self()
      handler = "search-request-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:tips, :search, :request],
        fn _event, _measure, meta, _config -> send(test, {:search, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    @tag :capture_log
    test "each request ranks hybrid when it can, else by keywords, without saying so", ctx do
      keyword = tip!(ctx, title: "Zebra crossing")
      meaning = tip!(ctx, title: "Striped horses", vector: query_vector())
      budget = [total: 3_000, query_embedding: 300]

      stub_provider(&respond_vector(&1, &2, query_vector()))
      assert {:ok, hybrid} = Content.search_tips(nil, "zebra")
      assert sorted_ids(hybrid) == Enum.sort([keyword.id, meaning.id])
      assert_received {:search, %{result: :hybrid, reason: nil}}

      # Without the vector column only the keyword branches can run.
      Repo.query!("ALTER TABLE review_search RENAME COLUMN embedding TO embedding_gone")

      assert {:ok, %{entries: [_], offset: 0, has_more: false} = page} =
               Content.search_tips(nil, "zebra")

      assert ids(page) == [keyword.id]
      assert_received {:search, %{result: :keyword, reason: :hybrid_ranking}}
      Repo.query!("ALTER TABLE review_search RENAME COLUMN embedding_gone TO embedding")

      for {respond, reason} <- [
            {fn conn, _input -> Plug.Conn.send_resp(conn, 503, "") end, {:http, 503}},
            {fn _conn, _input -> Process.sleep(:infinity) end, :deadline}
          ] do
        stub_provider(respond)
        assert {:ok, ^page} = Search.search_tips(nil, "zebra", [], budget)
        assert_received {:search, %{result: :keyword, reason: {:embedding, ^reason}}}
      end
    end

    @tag :capture_log
    test "an expired budget or failed keyword ranking is an error, not an empty page", ctx do
      tip!(ctx, title: "Zebra")
      test = self()

      stub_provider(fn _conn, _input ->
        send(test, {:requesting, self()})
        Process.sleep(:infinity)
      end)

      budget = [total: 300, query_embedding: 1_000]
      assert Search.search_tips(nil, "zebra", [], budget) == {:error, :unavailable}
      assert_received {:search, %{result: :error, reason: :deadline}}
      assert_received {:requesting, request}
      refute Process.alive?(request)

      stub_provider(&respond_vector(&1, &2, query_vector()))
      # The search relations become unresolvable for the rest of this test.
      Repo.query!("SET LOCAL search_path = pg_catalog")

      assert Content.search_tips(nil, "zebra") == {:error, :unavailable}
      assert_received {:search, %{result: :error, reason: :keyword_ranking}}
    end

    @tag :capture_log
    test "queries and the embedding scan share capacity, and dead holders release it", ctx do
      zebra = tip!(ctx, title: "Zebra")
      later = tip!(ctx, title: "Yak")
      test = self()

      holders =
        for _slot <- 1..8 do
          spawn(fn ->
            ProviderCapacity.run(System.monotonic_time(:millisecond) + 60_000, fn ->
              send(test, :holding)
              Process.sleep(:infinity)
            end)
          end)
        end

      on_exit(fn -> Enum.each(holders, &Process.exit(&1, :kill)) end)
      for _holder <- holders, do: assert_receive(:holding)

      stub_provider(&respond_vector(&1, &2, query_vector()))
      assert {:ok, page} = Content.search_tips(nil, "zebra")
      assert ids(page) == [zebra.id]
      assert_received {:search, %{result: :keyword, reason: {:embedding, :busy}}}
      # The scan stops at the first busy row and leaves the rest due.
      assert %{selected: 2, embedded: 0, failed: %{busy: 1}} = Embeddings.scan()
      assert provider_inputs() == []
      assert %{embed_after: nil} = search_row({:tip, later.id})

      # A cancelled search frees its slot, like any dead holder.
      Process.exit(hd(holders), :kill)

      stub_provider(fn _conn, _input ->
        send(test, :requesting)
        Process.sleep(:infinity)
      end)

      {:ok, searcher} = Task.start(fn -> Content.search_tips(nil, "zebra") end)
      assert_receive :requesting
      Process.exit(searcher, :kill)

      stub_provider(&respond_vector(&1, &2, query_vector()))
      assert {:ok, _page} = Content.search_tips(nil, "zebra")
      assert_received {:search, %{result: :hybrid}}
    end
  end

  describe "ranking bounds" do
    test "review collapse and fusion retain fixed candidate bounds", ctx do
      tips = for k <- 1..60, do: tip!(ctx, title: "Zebra", body: "Notes #{filler(k)}")

      assert {:ok, %{candidates: candidates, total: 50}} = Search.rank("zebra", offset: 40)
      assert Enum.map(candidates, & &1.tip_id) == tips |> Enum.slice(40, 10) |> Enum.map(& &1.id)
      assert {:ok, %{entries: [_ | _], has_more: false}} = Search.search(nil, "zebra", offset: 40)
      assert {:ok, %{entries: [], has_more: false}} = Search.search(nil, "zebra", offset: 60)
    end

    test "matching reviews collapse to one deterministic best review per tip", ctx do
      tip = tip!(ctx, title: "Plain parent")
      weaker = review!(tip, body: "Quokka #{filler(5)}")
      best = review!(tip, body: "Quokka quokka")
      _equal = review!(tip, body: "Quokka quokka")

      assert {:ok, %{candidates: [%{tip_id: tip_id, review_id: review_id}], total: 1}} =
               Search.rank("quokka", [])

      assert {tip_id, review_id} == {tip.id, best.id}
      assert weaker.id != review_id
    end

    test "the review cap counts reviews before collapse", ctx do
      crowded = tip!(ctx, title: "Crowded parent")
      bulk_reviews!(crowded, 1000, "Quokka quokka")
      outside = tip!(ctx, title: "Outside parent")
      review!(outside, body: "Quokka #{filler(20)}")

      assert {:ok, %{candidates: [%{tip_id: crowded_id, review_id: first_review}], total: 1}} =
               Search.rank("quokka", [])

      assert crowded_id == crowded.id

      assert first_review ==
               Repo.one!(from r in Review, where: r.tip_id == ^crowded.id, select: min(r.id))
    end

    test "each list ranks a tip once, by the better of the tip and its best review", ctx do
      top = tip!(ctx, title: "Zebra", body: "Notes", vector: near(1))
      reviewed = tip!(ctx, title: "Zebra", body: "Notes #{filler(3)}", vector: near(3))
      review = review!(reviewed, body: "Plain notes", vector: near(4))
      review_only = tip!(ctx, title: "Review-only parent")
      near_review = review!(review_only, body: "Plain words", vector: near(2))
      review!(review_only, body: "Other words", vector: near(30))

      assert {:ok, %{candidates: candidates, total: 3}} =
               Search.rank("zebra", embedding: query_vector())

      assert [
               %{tip_id: top_id, review_id: nil, score: top_score},
               %{tip_id: reviewed_id, review_id: review_id, score: reviewed_score},
               %{tip_id: review_tip_id, review_id: near_review_id, score: review_score}
             ] = candidates

      assert {top_id, reviewed_id, review_tip_id} == {top.id, reviewed.id, review_only.id}
      assert {review_id, near_review_id} == {review.id, near_review.id}
      assert_in_delta top_score, 1 / 61 + 1 / 61, 1.0e-12
      assert_in_delta reviewed_score, 1 / 62 + 1 / 63, 1.0e-12
      assert_in_delta review_score, 1 / 62, 1.0e-12

      assert {:ok, %{entries: [_top, _reviewed, %{matched_review_id: ^near_review_id}]}} =
               Search.search(nil, "zebra", embedding: query_vector())
    end

    test "pagination slices one fixed bounded ranking", ctx do
      branches = paginated_corpus(ctx, 55)
      opts = [embedding: query_vector()]

      pages =
        for offset <- 0..180//20 do
          assert {:ok, %{entries: entries, offset: ^offset, has_more: has_more}} =
                   Search.search(nil, "zebra", [offset: offset] ++ opts)

          assert length(entries) == 20
          assert has_more == offset < 180
          ids(entries)
        end

      all = List.flatten(pages)
      assert length(all) == 200
      assert length(Enum.uniq(all)) == 200

      # Each branch contributes exactly its own top 50 at every offset.
      for {_branch, tips} <- branches do
        {top, rest} = Enum.split(tips, 50)
        assert Enum.all?(top, &(&1 in all))
        refute Enum.any?(rest, &(&1 in all))
      end

      assert {:ok, %{candidates: first_page}} = Search.rank("zebra", opts)
      assert ids(first_page) == hd(pages)

      for offset <- [-20, 5, 200, 220] do
        assert Search.search(nil, "zebra", [offset: offset] ++ opts) == {:error, :invalid_offset}
      end
    end

    test "the last keyword page is short and an empty page has no next", ctx do
      for k <- 1..30, do: tip!(ctx, title: "Zebra", body: "Notes #{filler(k)}")

      assert {:ok, %{entries: first, has_more: true}} = Search.search(nil, "zebra", [])
      assert length(first) == 20
      assert {:ok, %{entries: last, has_more: false}} = Search.search(nil, "zebra", offset: 20)
      assert length(last) == 10
      assert {:ok, %{entries: [], has_more: false}} = Search.search(nil, "zebra", offset: 40)
    end
  end

  describe "hydration" do
    test "hydration rechecks visibility after candidate selection", ctx do
      first = tip!(ctx, title: "Zebra zebra zebra")
      hidden = tip!(ctx, title: "Zebra zebra SECRET title")
      deleted = tip!(ctx, title: "Zebra SECRET deleted")
      with_review = tip!(ctx, title: "Zebra", body: "Notes #{filler(4)}")

      review =
        review!(with_review,
          body: "Zebra zebra SECRET review",
          prompt: "SECRET prompt",
          output: "SECRET output",
          model_other: "SECRET model"
        )

      last = tip!(ctx, title: "Zebra", body: "Notes #{filler(8)}")

      assert {:ok, %{candidates: candidates}} = Search.rank("zebra", [])
      ranked = Enum.map(candidates, & &1.tip_id)

      assert Enum.all?(
               [first.id, hidden.id, deleted.id, with_review.id, last.id],
               &(&1 in ranked)
             )

      assert %{review_id: review_id} = Enum.find(candidates, &(&1.tip_id == with_review.id))
      assert review_id == review.id

      put_marker!(hidden, :hidden)
      put_marker!(deleted, :deleted)
      put_marker!(review, :hidden)

      surviving = Enum.reject(ranked, &(&1 in [hidden.id, deleted.id]))

      for {name, scope} <- viewers(ctx.author) do
        entries = Search.hydrate(scope, "zebra", candidates)
        assert ids(entries) == surviving, "viewer #{name}"
        assert %{matched_review_id: nil, excerpt: nil} = entry(entries, with_review.id)
        refute inspect(entries) =~ "SECRET"
        refute inspect(entries) =~ "secret"
      end

      put_marker!(with_review, :deleted)
      assert ids(Search.hydrate(nil, "zebra", candidates)) == surviving -- [with_review.id]
    end

    test "hydration drops a matched review of another tip", ctx do
      tip = tip!(ctx, title: "Zebra")
      other = review!(tip!(ctx, title: "Other"), body: "Zebra SECRET")

      assert [%{tip: %{id: tip_id}, matched_review_id: nil, excerpt: nil}] =
               Search.hydrate(nil, "zebra", [%{tip_id: tip.id, review_id: other.id}])

      assert tip_id == tip.id
    end

    test "summaries votes capabilities and excerpt sources are projected", ctx do
      body = tip!(ctx, title: "Body parent", model_id: "claude", environment_id: "ide")
      prompt = tip!(ctx, title: "Prompt parent")
      result = tip!(ctx, title: "Result parent")
      setup = tip!(ctx, title: "Setup parent")
      long = tip!(ctx, title: "Long parent")

      body_review = review!(body, body: "Quokka in the review body.")
      prompt_review = review!(prompt, body: "Plain review.", prompt: "Ask the quokka")
      result_review = review!(result, body: "Plain review.", output: ~s(error: "quokka" failed))

      setup_review =
        review!(setup, body: "Plain review.", model_other: "Quokka-7B", environment_id: "cli")

      long_text =
        String.duplicate("filler words ", 300) <>
          "the quokka appears here " <> String.duplicate("tail ", 300)

      long_review = review!(long, body: long_text)

      viewer = user_fixture()
      vote_fixture(body, %{user_id: viewer.id, value: -1})

      entries = entries(search!(Scope.for_user(viewer), "quokka"))

      assert %{tip: tip, matched_review_id: body_review_id, excerpt: %{source: :body, text: text}} =
               entry(entries, body.id)

      assert body_review_id == body_review.id
      assert text == "Quokka in the review body."

      assert %{
               state: :visible,
               title: "Body parent",
               slug: "body-parent",
               removed: false,
               tag: %{id: "other", label: "Other technique"},
               model: %{id: "claude", label: "Claude"},
               environment: %{id: "ide", label: "IDE"},
               author: %{handle: handle},
               score: -1,
               review_count: 1,
               viewer_vote: -1,
               capabilities: %{vote: true, edit: false, delete: false, report: true}
             } = tip

      assert handle == ctx.author.handle

      assert %{matched_review_id: id, excerpt: %{source: :prompt, text: "Ask the quokka"}} =
               entry(entries, prompt.id)

      assert id == prompt_review.id

      assert %{
               matched_review_id: id,
               excerpt: %{source: :result, text: ~s(error: "quokka" failed)}
             } =
               entry(entries, result.id)

      assert id == result_review.id

      assert %{matched_review_id: id, excerpt: %{source: :setup, text: "Quokka-7B · CLI"}} =
               entry(entries, setup.id)

      assert id == setup_review.id

      assert %{matched_review_id: id, excerpt: %{source: :body, text: excerpt}} =
               entry(entries, long.id)

      assert id == long_review.id
      assert excerpt =~ "the quokka appears here"
      assert String.length(excerpt) <= 282
      assert String.starts_with?(excerpt, "…") and String.ends_with?(excerpt, "…")

      assert %{tip: %{viewer_vote: nil, capabilities: %{vote: false, report: false}}} =
               entry(entries(search!(nil, "quokka")), body.id)

      assert %{tip: %{capabilities: %{edit: true, delete: true}}} =
               entry(entries(search!(Scope.for_user(ctx.author), "quokka")), body.id)
    end

    test "hydration reads are batched", ctx do
      tips = for k <- 1..6, do: tip!(ctx, title: "Zebra", body: "Notes #{filler(k)}")
      for tip <- tips, do: review!(tip, body: "Zebra review")
      scope = Scope.for_user(user_fixture())

      assert {:ok, %{candidates: candidates}} = Search.rank("zebra", [])
      assert length(candidates) == 6

      {_entries, few} =
        count_queries(fn -> Search.hydrate(scope, "zebra", Enum.take(candidates, 1)) end)

      {_entries, many} = count_queries(fn -> Search.hydrate(scope, "zebra", candidates) end)

      assert few == many
      assert {[], 0} = count_queries(fn -> Search.hydrate(scope, "zebra", []) end)
    end
  end

  describe "vector retrieval" do
    test "filtered relaxed HNSW is re-sorted and agrees with exact neighbors", ctx do
      # 100 unfiltered tips are nearer the query than all 20 selected tips, so
      # an HNSW scan without iterative relaxation (ef_search 40) finds none of
      # the selected tips. Each tip has one review on the same separated axis.
      corpus =
        for step <- 1..120 do
          tag = if step > 100, do: "persona", else: "phrase"
          tip = tip!(ctx, title: "Vector tip", tag_id: tag, vector: near(step))
          review!(tip, body: "Vector review", vector: near(step))
          {tag, tip.id}
        end

      selected = for {"persona", id} <- corpus, do: id
      opts = [embedding: query_vector(), tag_id: "persona"]
      k = min(50, length(selected))

      exact =
        in_plan(:sequential, fn ->
          {:ok, %{candidates: candidates}} = Search.rank("unmatched", opts)
          ids(candidates)
        end)

      for {kind, column, index} <- [
            {:tip, "tip_id", "tips_embedding"},
            {:review, "review_id", "reviews_embedding"}
          ] do
        assert exact_neighbors(kind, column, "persona", k) == selected

        in_plan(:index, fn ->
          assert {"Index Scan", index} in scans(explain("unmatched", opts))
        end)
      end

      approximate =
        in_plan(:index, fn ->
          {:ok, %{candidates: candidates}} = Search.rank("unmatched", opts)
          ids(candidates)
        end)

      recall =
        MapSet.size(
          MapSet.intersection(MapSet.new(Enum.take(approximate, k)), MapSet.new(selected))
        ) / k

      assert recall == 1.0
      # Tip and review distances agree per tip, so fusion orders by distance.
      assert approximate == selected
      assert exact == selected
    end
  end

  ## Corpus helpers

  defp tip!(ctx, attrs) do
    {vector, attrs} = Keyword.pop(attrs, :vector)
    ctx.author |> tip_fixture(Map.new(attrs)) |> index!(vector)
  end

  defp review!(tip, attrs) do
    {vector, attrs} = Keyword.pop(attrs, :vector)

    attrs =
      attrs
      |> Map.new()
      |> Map.put_new_lazy(:user_id, fn -> user_fixture().id end)

    tip |> review_fixture(attrs) |> index!(vector)
  end

  defp index!(content, vector) do
    {table, column, write} =
      case content do
        %Tip{} -> {"tip_search", "tip_id", &Search.write_tip_text/1}
        %Review{} -> {"review_search", "review_id", &Search.write_review_text/1}
      end

    {:ok, :ok} = Repo.transact(fn -> {:ok, write.(content.id)} end)

    if vector do
      Repo.query!(
        "UPDATE #{table} SET embedding = $2::text::vector(1024) WHERE #{column} = $1",
        [content.id, vector_text(vector)]
      )
    end

    content
  end

  defp bulk_reviews!(tip, count, body) do
    %{rows: user_rows} =
      Repo.query!(
        """
        INSERT INTO users (handle, email, inserted_at, updated_at)
        SELECT 'bulk' || $1::text || '_' || g, 'bulk' || $1::text || '_' || g || '@example.com', now(), now()
        FROM generate_series(1, $2::int) g
        RETURNING id
        """,
        [Integer.to_string(System.unique_integer([:positive])), count]
      )

    %{num_rows: ^count} =
      Repo.query!(
        """
        INSERT INTO reviews (tip_id, user_id, submission_key, body, created_at)
        SELECT $1, u.id, gen_random_uuid(), $3, now()
        FROM unnest($2::bigint[]) AS u(id)
        ORDER BY u.id
        """,
        [tip.id, List.flatten(user_rows), body]
      )

    Repo.query!(
      "INSERT INTO review_search (review_id, search_text) SELECT id, body FROM reviews WHERE tip_id = $1",
      [tip.id]
    )
  end

  # One tip reachable through each branch only, with its parent setup and,
  # where a review matches, the reviewer's own differing setup.
  defp branch_tips(ctx, parent, reviewer) do
    tips_bm25 = tip!(ctx, [title: "Zebra crossing"] ++ parent)
    tips_vec = tip!(ctx, [title: "Vector parent", vector: near(1)] ++ parent)
    reviews_bm25 = tip!(ctx, [title: "Lexical review parent"] ++ parent)
    review!(reviews_bm25, [body: "Zebra seen by the reviewer"] ++ reviewer)
    reviews_vec = tip!(ctx, [title: "Vector review parent"] ++ parent)
    review!(reviews_vec, [body: "Plain review", vector: near(2)] ++ reviewer)

    %{
      tips_bm25: tips_bm25.id,
      tips_vec: tips_vec.id,
      reviews_bm25: reviews_bm25.id,
      reviews_vec: reviews_vec.id
    }
  end

  # `per_branch` tips reachable through each branch only, best first.
  defp paginated_corpus(ctx, per_branch) do
    reviewer = user_fixture()

    %{
      tips_bm25:
        for(k <- 1..per_branch, do: tip!(ctx, title: "Zebra", body: "Notes #{filler(k)}").id),
      tips_vec: for(k <- 1..per_branch, do: tip!(ctx, title: "Vector tip", vector: near(k)).id),
      reviews_bm25:
        for k <- 1..per_branch do
          tip = tip!(ctx, title: "Lexical review parent")
          review!(tip, body: "Zebra #{filler(k)}", user_id: reviewer.id)
          tip.id
        end,
      reviews_vec:
        for k <- 1..per_branch do
          tip = tip!(ctx, title: "Vector review parent")
          review!(tip, body: "Plain review", user_id: reviewer.id, vector: near(k))
          tip.id
        end
    }
  end

  defp filler(count), do: Enum.map_join(1..count, " ", &"filler#{&1}")

  ## Vectors: a unit query on axis 0 and unit documents at increasing angles
  # on one great circle. Each document's nearest neighbours are the adjacent
  # steps, so the HNSW graph stays connected; vectors on separate orthogonal
  # axes form a hub-and-spoke graph that HNSW cannot fully traverse.

  defp query_vector, do: [1.0 | List.duplicate(0.0, @dimensions - 1)]

  defp plane(x, y), do: [x, y | List.duplicate(0.0, @dimensions - 2)]

  defp near(step) do
    angle = step * 0.01
    [:math.cos(angle), :math.sin(angle) | List.duplicate(0.0, @dimensions - 2)]
  end

  defp vector_text(vector),
    do: "[" <> Enum.map_join(vector, ",", &Float.to_string(&1 * 1.0)) <> "]"

  defp exact_neighbors(kind, column, tag, k) do
    {join, tip_column} =
      case kind do
        :tip ->
          {"JOIN tips t ON t.id = s.tip_id", "s.tip_id"}

        :review ->
          {"JOIN reviews r ON r.id = s.review_id JOIN tips t ON t.id = r.tip_id", "r.tip_id"}
      end

    in_plan(:sequential, fn ->
      Repo.query!(
        """
        SELECT #{tip_column} FROM #{kind}_search s #{join}
        WHERE t.tag_id = $1 AND s.embedding IS NOT NULL
        ORDER BY s.embedding <=> $2::text::vector(1024), s.#{column}
        LIMIT $3
        """,
        [tag, vector_text(query_vector()), k]
      ).rows
      |> List.flatten()
    end)
  end

  ## Search helpers

  defp search!(scope, query, opts \\ []) do
    assert {:ok, %{entries: _} = result} = Search.search(scope, query, opts)
    result
  end

  defp entries(%{entries: entries}), do: entries

  defp entry(entries, tip_id), do: Enum.find(entries, &(&1.tip.id == tip_id))

  defp ids(%{entries: entries}), do: ids(entries)
  defp ids(list) when is_list(list), do: Enum.map(list, &id/1)

  defp id(%{tip: %{id: id}}), do: id
  defp id(%{tip_id: id}), do: id

  defp sorted_ids(result), do: result |> ids() |> Enum.sort()

  defp lexical_score(kind, id, query) do
    index = if kind == :tip, do: "tips_bm25", else: "reviews_bm25"

    %{rows: [[score]]} =
      Repo.query!(
        "SELECT search_text <@> to_bm25query($2, '#{index}') FROM #{kind}_search WHERE #{kind}_id = $1",
        [id, query]
      )

    score
  end

  ## Plans

  defp in_plan(plan, fun) do
    settings =
      case plan do
        :index -> ["SET LOCAL enable_seqscan = off", "SET LOCAL enable_sort = off"]
        :sequential -> ["SET LOCAL enable_indexscan = off", "SET LOCAL enable_bitmapscan = off"]
      end

    {:error, {:done, result}} =
      Repo.transact(fn ->
        Enum.each(settings, &Repo.query!/1)
        Repo.rollback({:done, fun.()})
      end)

    result
  end

  defp explain(query, opts) do
    {:ok, %{sql: sql, params: params, settings: settings}} = Search.ranking_statement(query, opts)
    Enum.each(settings, &Repo.query!/1)
    assert %{rows: [[plan]]} = Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params)
    plan
  end

  defp scans(%{} = node) do
    own =
      case node do
        %{"Node Type" => type, "Index Name" => index} -> [{type, index}]
        %{"Node Type" => "Seq Scan" = type, "Relation Name" => relation} -> [{type, relation}]
        _other -> []
      end

    own ++ Enum.flat_map(Map.values(node), &scans/1)
  end

  defp scans(list) when is_list(list), do: Enum.flat_map(list, &scans/1)
  defp scans(_value), do: []

  defp count_queries(fun) do
    test = self()
    handler = "search-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:tips, :repo, :query],
        fn _event, _measure, _meta, _config ->
          if test in [self() | Process.get(:"$callers", [])], do: send(test, :query)
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain(0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(count) do
    receive do
      :query -> drain(count + 1)
    after
      0 -> count
    end
  end
end
