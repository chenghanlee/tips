defmodule Tips.SearchGateTest do
  # The gate holds every shared provider-capacity slot during its saturation step.
  use Tips.DataCase, async: false

  import Ecto.Query

  alias Tips.Content.Search.EmbeddingProvider
  alias Tips.Content.Tip
  alias Tips.{SearchGate, SearchGateVectors}

  setup do
    {:ok, fixtures} = SearchGate.load()

    Req.Test.stub(SearchGate, fn conn ->
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
                     "tag" => "deepinfra/us",
                     "provider_name" => "DeepInfra",
                     "status" => 0,
                     "context_length" => 32_768,
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
    stub_provider(fn _input, _documents_sent -> {200, "DeepInfra"} end)

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

  for {failure, response} <- [
        {"an HTTP error", {500, "DeepInfra"}},
        {"another upstream", {200, "Nebius"}}
      ] do
    test "stops the scan at the first document request that gets #{failure} and calls no query",
         %{fixtures: fixtures} do
      failed = unquote(Macro.escape(response))

      stub_provider(fn _input, documents_sent ->
        if documents_sent == 3, do: failed, else: {200, "DeepInfra"}
      end)

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
  # signal, and reports each request to the gate as Finch telemetry would.
  defp stub_provider(response_for) do
    test = self()
    counter = :counters.new(1, [])

    Req.Test.stub(EmbeddingProvider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"input" => [input]} = JSON.decode!(body)
      send(test, {:provider_input, input})
      :counters.add(counter, 1, 1)
      {status, upstream} = response_for.(input, :counters.get(counter, 1))

      response =
        JSON.encode!(%{
          "data" => [%{"index" => 0, "embedding" => bag_of_words(input)}],
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
