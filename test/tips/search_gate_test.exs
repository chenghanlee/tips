defmodule Tips.SearchGateTest do
  # The gate holds every shared provider-capacity slot during its saturation step.
  use Tips.DataCase, async: false

  import Ecto.Query

  alias Tips.Content
  alias Tips.Content.Search.EmbeddingProvider
  alias Tips.Content.Tip
  alias Tips.{SearchGate, SearchGateVectors}

  setup do
    {:ok, fixtures} = SearchGate.load()

    Req.Test.stub(SearchGate, fn conn ->
      SearchGate.request_started()

      {path, body} =
        case conn.request_path do
          "/api/v1/key" ->
            {"/api/v1/key", %{"data" => %{"limit" => nil, "limit_remaining" => nil}}}

          endpoints ->
            {endpoints,
             %{
               "data" => %{
                 "endpoints" => [
                   %{
                     "tag" => "nebius",
                     "provider_name" => "Nebius",
                     "status" => 0,
                     "context_length" => 32_000,
                     "pricing" => %{"prompt" => "0.00000001"}
                   }
                 ]
               }
             }}
        end

      SearchGate.observe(SearchGate.request_record(path, nil, 200, JSON.encode!(body), 1))
      Req.Test.json(conn, body)
    end)

    %{fixtures: fixtures}
  end

  test "runs every protocol step through the application and sends only eligible documents",
       %{fixtures: fixtures} do
    stub_provider(nil)

    assert {_passed_or_failed, report} =
             SearchGate.run(fixtures,
               preflight_plug: {Req.Test, SearchGate},
               require_empty: false
             )

    assert %{stopped: nil, usage: %{requests: 90, failed_requests: 0}} = report

    assert %{embedded: 40, requests: 40, unmatched_inputs: 0, ineligible_embedded: []} =
             report.scan

    ineligible =
      for %{"id" => id} = doc <- fixtures.corpus,
          id in ~w(hidden-01 deleted-01 review-h1),
          do: doc["body"]

    refute Enum.any?(provider_inputs(), fn input ->
             Enum.any?(ineligible, &String.contains?(input, &1))
           end)

    passed = for %{passed: true, name: name} <- report.gates, do: name

    for gate <- ~w(provider_requests_succeed single_identity passes_hybrid long_input_sent_whole
                   filters_exact deep_offset_empty saturation_within_budget burst_pages),
        do: assert(gate in passed, "#{gate} failed: #{inspect(report.gates)}")

    assert JSON.encode!(report)
  end

  test "refuses without opt-in before it seeds or calls the provider", %{fixtures: fixtures} do
    assert {:stopped, %{stopped: ":not_opted_in", usage: %{requests: 0}}} =
             SearchGate.run(fixtures)

    refute Repo.exists?(Tip)
  end

  test "loads the frozen vectors into the seeded corpus's search tables" do
    {:ok, fixtures} = SearchGate.load()
    {:ok, ids} = Repo.transact(fn -> {:ok, SearchGate.seed_corpus(fixtures.corpus)} end)
    fixture = SearchGateVectors.load!(ids)

    stored =
      for %{"id" => id} <- fixture["documents"] do
        query =
          case ids[id] do
            {:tip, row} -> from(s in "tip_search", where: s.tip_id == ^row)
            {:review, row} -> from(s in "review_search", where: s.review_id == ^row)
          end

        Repo.one!(select(query, [s], fragment("?::text", s.embedding)))
      end

    assert length(stored) == 40
    assert stored == Enum.map(fixture["documents"], & &1["embedding"])
  end

  test "hybrid search over the frozen vectors meets the gate's relevance rules" do
    {:ok, %{corpus: corpus, queries: queries, gate: gate}} = SearchGate.load()
    {:ok, ids} = Repo.transact(fn -> {:ok, SearchGate.seed_corpus(corpus)} end)
    vectors = ids |> SearchGateVectors.load!() |> SearchGateVectors.queries()
    corpus_ids = Map.new(ids, fn {id, row} -> {row, id} end)
    models = SearchGate.setup(corpus)

    parents =
      for %{"kind" => "review"} = doc <- corpus, into: %{}, do: {doc["id"], doc["parent_id"]}

    respond_vector(fn input ->
      %{"id" => id} = Enum.find(queries, &String.ends_with?(input, &1["text"]))
      vectors[id]
    end)

    top = fn text, opts ->
      assert {:ok, %{entries: entries}} = Content.search_tips(nil, text, opts)

      for entry <- Enum.take(entries, 5) do
        %{
          tip: corpus_ids[{:tip, entry.tip.id}],
          review: corpus_ids[{:review, entry.matched_review_id}]
        }
      end
    end

    handler = {__MODULE__, self()}
    test = self()

    :telemetry.attach(
      handler,
      [:tips, :search, :request],
      fn _event, _measure, meta, _ ->
        send(test, {:search, meta.result})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    results =
      for %{"id" => id, "text" => text, "relevant" => relevant} <- queries do
        hybrid = top.(text, [])

        # Gate rule "filtered": per relevant model, only that model, recall kept.
        filters_hold =
          relevant
          |> Enum.group_by(&models[Map.get(parents, &1, &1)].model)
          |> Enum.all?(fn {model, docs} ->
            filtered = top.(text, model_id: model)

            Enum.all?(filtered, &(models[&1.tip].model == model)) and
              SearchGate.recall(docs, filtered, ids).recall >=
                SearchGate.recall(docs, hybrid, ids).recall
          end)

        {id, SearchGate.recall(relevant, hybrid, ids), filters_hold}
      end

    assert for({id, %{hit: false}, _filters} <- results, do: id) == []
    assert for({id, _recall, false} <- results, do: id) == []
    macro = Enum.sum(for {_id, %{recall: recall}, _filters} <- results, do: recall) / 10
    assert macro >= gate["gate"]["min_macro_recall"]
    refute_received {:search, :keyword}
    refute_received {:search, :error}
  end

  for {failure, third} <- [
        {"an HTTP error", {:status, 500}},
        {"another upstream", {:upstream, "DeepInfra"}},
        {"an all-zero vector", :zero_vector},
        {"a vector at index 1", :index_one},
        {"no response before its deadline", :no_response}
      ] do
    test "stops the scan at the first document request that gets #{failure} and calls no query",
         %{fixtures: fixtures} do
      provider = Application.get_env(:tips, EmbeddingProvider)
      Application.put_env(:tips, EmbeddingProvider, Keyword.put(provider, :deadline, 200))
      on_exit(fn -> Application.put_env(:tips, EmbeddingProvider, provider) end)
      stub_provider(unquote(Macro.escape(third)))

      assert {:stopped, report} =
               SearchGate.run(fixtures,
                 preflight_plug: {Req.Test, SearchGate},
                 require_empty: false
               )

      assert %{stopped: ":provider_error", usage: %{requests: 5, failed_requests: 1}} = report
      assert %{requests: 3, embedded: 2} = report.scan
      assert length(provider_inputs()) == 3
      assert JSON.encode!(report)
    end
  end

  # Responds as the selected runtime with bag-of-words vectors, so ranking has
  # signal, and reports each request to the gate as Finch telemetry would. The
  # third document request gets `third`, unless it is `nil`.
  defp stub_provider(third) do
    test = self()
    counter = :counters.new(1, [])

    Req.Test.stub(EmbeddingProvider, fn conn ->
      SearchGate.request_started()
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"input" => [input]} = JSON.decode!(body)
      send(test, {:provider_input, input})
      :counters.add(counter, 1, 1)
      failure = if :counters.get(counter, 1) == 3, do: third
      if failure == :no_response, do: Process.sleep(:infinity)

      {status, upstream} =
        case failure do
          {:status, status} -> {status, "Nebius"}
          {:upstream, upstream} -> {200, upstream}
          _ok_or_vector -> {200, "Nebius"}
        end

      embedding =
        if failure == :zero_vector, do: List.duplicate(0.0, 1024), else: bag_of_words(input)

      index = if failure == :index_one, do: 1, else: 0

      response =
        JSON.encode!(%{
          "data" => [%{"index" => index, "embedding" => embedding}],
          "model" => "Qwen/Qwen3-Embedding-8B",
          "provider" => upstream,
          "usage" => %{"prompt_tokens" => byte_size(input), "cost" => 1.0e-8}
        })

      SearchGate.observe(
        SearchGate.request_record("/api/v1/embeddings", input, status, response, 1)
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, response)
    end)
  end

  # Responds to each query embedding request with `vector.(input)`.
  defp respond_vector(vector) do
    Req.Test.stub(EmbeddingProvider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"input" => [input]} = JSON.decode!(body)

      Req.Test.json(conn, %{
        "data" => [%{"index" => 0, "embedding" => vector.(input)}],
        "model" => "Qwen/Qwen3-Embedding-8B",
        "provider" => "Nebius"
      })
    end)
  end

  defp bag_of_words(text) do
    counts =
      text
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/, trim: true)
      |> Enum.frequencies_by(&:erlang.phash2(&1, 1024))

    for i <- 0..1023, do: Map.get(counts, i, 0) * 1.0
  end

  defp provider_inputs(acc \\ []) do
    receive do
      {:provider_input, input} -> provider_inputs([input | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
