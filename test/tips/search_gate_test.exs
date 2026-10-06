defmodule Tips.SearchGateTest do
  # The gate holds every shared provider-capacity slot during its saturation step.
  use Tips.DataCase, async: false

  alias Tips.Content.Search.EmbeddingProvider
  alias Tips.SearchGate

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
                     "tag" => "deepinfra",
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
    stub_provider(fn _input, _documents_sent -> 200 end)

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

  test "stops the scan at the first failed document request and calls no query", %{
    fixtures: fixtures
  } do
    stub_provider(fn _input, documents_sent -> if documents_sent == 3, do: 500, else: 200 end)

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

  # Responds as the selected runtime with bag-of-words vectors, so ranking has
  # signal, and reports each request to the gate as Finch telemetry would.
  defp stub_provider(status_for) do
    test = self()
    counter = :counters.new(1, [])

    Req.Test.stub(EmbeddingProvider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"input" => [input]} = JSON.decode!(body)
      send(test, {:provider_input, input})
      :counters.add(counter, 1, 1)
      status = status_for.(input, :counters.get(counter, 1))

      response =
        JSON.encode!(%{
          "data" => [%{"index" => 0, "embedding" => bag_of_words(input)}],
          "model" => "Qwen/Qwen3-Embedding-8B",
          "provider" => "DeepInfra",
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
