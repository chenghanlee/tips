defmodule Tips.SearchProbeTest do
  # Provider scenarios use Req plugs; nothing here reaches a real provider.
  use ExUnit.Case, async: true

  alias Tips.SearchProbe

  @moduletag :tmp_dir

  @secret "sentinel-secret-key"
  # The provider's documented spelling of the requested candidate and pinned upstream.
  @identity %{"model" => "Qwen/Qwen3-Embedding-8B", "provider" => "DeepInfra"}

  setup_all do
    {:ok, fixtures} = SearchProbe.load(SearchProbe.fixtures_dir())
    %{fixtures: fixtures}
  end

  test "corpus has ten judged queries and valid eligible document references", %{
    fixtures: fixtures
  } do
    %{corpus: corpus, queries: queries, gate: gate} = fixtures
    eligible = corpus |> SearchProbe.eligible() |> MapSet.new(& &1["id"])

    assert [_, _, _, _, _, _, _, _, _, _] = queries
    assert MapSet.size(eligible) in 30..50
    assert gate["gate"]["k"] == 5

    assert queries |> Enum.map(& &1["category"]) |> MapSet.new() ==
             MapSet.new(~w(scoped_change setup_environment long_output punctuation_error))

    for query <- queries do
      assert [_ | _] = query["relevant"]
      assert Enum.all?(query["relevant"], &(&1 in eligible)), query["id"]
      assert String.trim(query["rationale"]) != ""
    end

    # Relevant material sits at the beginning, middle and end of documents over the cap.
    cap = gate["preparation"]["document_max_bytes"]
    long = Enum.filter(corpus, &(byte_size(SearchProbe.document_text(&1)) > cap))
    assert Enum.count(long, &(&1["id"] in eligible)) >= 3

    broken = put_in(fixtures.queries, [%{hd(queries) | "relevant" => ["hidden-01"]}])
    assert {:error, errors} = SearchProbe.validate(broken)
    assert Enum.any?(errors, &(&1 =~ "exactly ten queries"))
    assert Enum.any?(errors, &(&1 =~ "q01" and &1 =~ "hidden-01"))
  end

  test "scores known rankings deterministically" do
    documents = %{
      "b" => [1.0, 0.0],
      "a" => [1.0, 0.0],
      "c" => [0.6, 0.8],
      "d" => [0.0, 1.0]
    }

    # Equal scores break ties by id.
    assert [{"a", 1.0}, {"b", 1.0}, {"c", 0.6}, {"d", +0.0}] =
             SearchProbe.rank([1.0, 0.0], documents)

    assert SearchProbe.recall(["a", "b", "c"], ["c", "x"], 2) == 0.0
    assert SearchProbe.recall(["a", "b", "c"], ["c", "x"], 3) == 0.5
    assert SearchProbe.recall(["a", "b", "c"], ["a"], 1) == 1.0
    assert SearchProbe.p95([5, 1, 4, 2, 3]) == 5
    assert SearchProbe.p95(Enum.to_list(1..40)) == 38
  end

  test "prepares documents and instructed queries distinctly", %{fixtures: fixtures} do
    %{gate: gate} = fixtures
    instruction = gate["preparation"]["query_instruction"]

    tip = %{"kind" => "tip", "title" => "Title", "body" => "Body text"}
    review = %{"kind" => "review", "title" => nil, "body" => "Review text"}
    assert SearchProbe.document_text(tip) == "Title\n\nBody text"
    assert SearchProbe.document_text(review) == "Review text"

    assert %{text: "Title\n\nBody text", truncated: false} =
             SearchProbe.prepare_document(tip, gate)

    assert instruction ==
             "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:"

    assert {:ok, prepared} = SearchProbe.prepare_query("why: \"x\" fails?", gate)
    assert prepared == instruction <> "why: \"x\" fails?"
    refute String.starts_with?(SearchProbe.document_text(tip), "Instruct:")

    assert {:error, :blank_query} = SearchProbe.prepare_query(" \n ", gate)
    assert {:ok, _} = SearchProbe.prepare_query(String.duplicate("é", 512), gate)

    assert {:error, :query_too_long} =
             SearchProbe.prepare_query(String.duplicate("a", 1025), gate)
  end

  test "bounds UTF-8 inputs deterministically without breaking characters", %{fixtures: fixtures} do
    separator = "\n[...]\n"
    assert SearchProbe.bound("short", 64, separator) == "short"

    for text <- [String.duplicate("aé€😀", 200), String.duplicate("😀", 300)],
        max <- [64, 65, 66, 67, 101] do
      bounded = SearchProbe.bound(text, max, separator)
      assert String.valid?(bounded)
      assert byte_size(bounded) <= max
      assert byte_size(bounded) >= max - 6
      assert [head, tail] = String.split(bounded, separator)
      assert String.starts_with?(text, head)
      assert String.ends_with?(text, tail)
      # Each side may back off up to three bytes; an odd budget gives the tail one more.
      assert abs(byte_size(head) - byte_size(tail)) <= 4
      assert SearchProbe.bound(text, max, separator) == bounded
    end

    %{gate: gate, corpus: corpus} = fixtures
    long = Enum.find(corpus, &(&1["id"] == "long-03"))
    prepared = SearchProbe.prepare_document(long, gate)
    assert prepared.truncated
    assert byte_size(prepared.text) <= 16_384
    assert prepared.full_bytes == byte_size(SearchProbe.document_text(long))
    # The lesson at the end of long-03 survives in the tail.
    assert prepared.text =~ "at the very end of the prompt"
  end

  test "validates and normalizes provider vectors" do
    provider = provider(respond(fn _inputs -> [vector([3.0, 4.0], 1024)] end))
    assert {:ok, %{vectors: [vec], returned_length: 1024}} = SearchProbe.embed(["x"], provider)
    assert [0.6, 0.8 | _] = vec
    assert_in_delta norm(vec), 1.0, 1.0e-9

    # An ignored dimensions parameter returns 4096 values; keep the first 1024 and renormalize.
    ignored_values = [0.0, 2.0] |> vector_values(4096) |> List.replace_at(2000, 9.0)
    ignored = provider(respond(fn _ -> [%{"index" => 0, "embedding" => ignored_values}] end))

    assert {:ok, %{vectors: [vec], returned_length: 4096}} = SearchProbe.embed(["x"], ignored)
    assert [+0.0, 1.0 | _] = vec
    assert length(vec) == 1024

    # Once a length is established, a different length is an error.
    pinned = %{ignored | expected_length: 1024}
    assert {:error, {:vector_length, 4096}} = SearchProbe.embed(["x"], pinned)

    for {data, error} <- [
          {[vector([1.0], 512)], {:vector_length, 512}},
          {[vector([0.0], 1024)], :zero_vector},
          {[vector([1.0, "2"], 1024)], :non_numeric_vector},
          {[%{"index" => 1, "embedding" => vector_values([1.0], 1024)}], :bad_indices},
          {[], :bad_indices}
        ] do
      assert {:error, ^error} = SearchProbe.embed(["x"], provider(respond(fn _ -> data end)))
    end

    duplicate = fn _ -> [vector([1.0], 1024), vector([1.0], 1024)] end
    assert {:error, :bad_indices} = SearchProbe.embed(["x", "y"], provider(respond(duplicate)))

    malformed = fn conn -> Req.Test.json(conn, %{"object" => "list"}) end
    assert {:error, :malformed_response} = SearchProbe.embed(["x"], provider(malformed))
  end

  test "omits ineligible documents and drafts before HTTP", %{
    fixtures: fixtures,
    tmp_dir: tmp_dir
  } do
    test = self()

    plug =
      stub_provider(fixtures, fn conn, body ->
        send(test, {:http, conn.method, conn.request_path, body})
        :pass
      end)

    report = run!(fixtures, plug, tmp_dir)
    assert report["status"] == "passed"

    bodies = collect_http()
    sent = Enum.map_join(bodies, "\n", fn {_method, _path, body} -> body end)
    refute sent =~ "SENTINEL"
    refute sent =~ @secret

    eligible = SearchProbe.eligible(fixtures.corpus)
    long = Enum.filter(eligible, &SearchProbe.prepare_document(&1, fixtures.gate).truncated)
    embeddings = Enum.filter(bodies, &match?({"POST", "/api/v1/embeddings", _}, &1))
    assert length(embeddings) == length(eligible) + length(long) + 30
    assert report["usage"]["requests"] == length(bodies)
    assert %{"preflight" => %{"plan" => %{"requests" => planned}}} = report
    assert is_integer(planned) and planned >= length(bodies)
  end

  test "default invocation never calls a real provider", %{fixtures: fixtures, tmp_dir: tmp_dir} do
    test = self()

    plug = fn conn ->
      send(test, :http)
      Req.Test.json(conn, %{})
    end

    output = Path.join(tmp_dir, "report.json")
    opts = [req_options: [plug: plug], api_key: @secret]

    {status, printed} = main([], opts)
    assert status == 0
    assert printed =~ "fixtures valid"
    assert printed =~ fixtures.hashes["gate"]

    assert {0, _} = main(["--validate"], opts)
    assert {2, printed} = main(["--real", "--output", output], [mode: :stub] ++ opts)
    assert printed =~ "TIPS_REAL_PROVIDERS=1"
    assert {2, _} = main(["--output", output], [mode: :real] ++ opts)
    assert {2, _} = main(["--bogus"], [mode: :real] ++ opts)

    refute_received :http
    refute File.exists?(output)
  end

  test "provider errors remain redacted failures", %{fixtures: fixtures, tmp_dir: tmp_dir} do
    leak = fn conn, status ->
      conn
      |> Plug.Conn.put_resp_header("x-debug", @secret)
      |> Plug.Conn.send_resp(status, ~s({"error":{"message":"sentinel-body #{@secret}"}}))
    end

    for {failure, status, blocker} <- [
          {&leak.(&1, 401), "blocked", "http_401"},
          {&leak.(&1, 402), "blocked", "http_402"},
          {&leak.(&1, 429), "blocked", "http_429"},
          {&leak.(&1, 503), "failed", nil},
          {&Req.Test.transport_error(&1, :timeout), "failed", nil},
          {&Req.Test.transport_error(&1, :econnrefused), "blocked", "transport"},
          {&Req.Test.json(&1, %{"data" => [%{"index" => 0, "embedding" => [nil]}]}), "failed",
           nil}
        ] do
      plug =
        stub_provider(fixtures, fn
          %{request_path: "/api/v1/embeddings"} = conn, _body -> {:respond, failure.(conn)}
          _conn, _body -> :pass
        end)

      report = run!(fixtures, plug, tmp_dir)
      json = File.read!(Path.join(tmp_dir, "report.json"))

      assert report["status"] == status
      assert report["blocker"] == blocker
      assert %{"name" => "provider_calls", "passed" => false} = hd(report["gates"])
      refute json =~ "sentinel"
      refute json =~ "authorization"
    end

    {1, _} =
      main(["--real", "--output", Path.join(tmp_dir, "missing.json")],
        mode: :real,
        api_key: " ",
        req_options: [plug: fn _conn -> flunk("HTTP without credentials") end]
      )

    assert %{"status" => "blocked", "blocker" => "missing_credentials"} =
             tmp_dir |> Path.join("missing.json") |> File.read!() |> Jason.decode!()
  end

  test "writes reproducible report and exits nonzero for failed gates", %{
    fixtures: fixtures,
    tmp_dir: tmp_dir
  } do
    output = Path.join(tmp_dir, "report.json")
    plug = stub_provider(fixtures, fn _conn, _body -> :pass end)

    assert {0, printed} =
             main(["--real", "--output", output],
               mode: :real,
               api_key: @secret,
               req_options: [plug: plug]
             )

    assert printed =~ "passed"
    report = output |> File.read!() |> Jason.decode!()

    assert %{
             "status" => "passed",
             "fixtures" => %{"gate_version" => "54-gate-v1", "hashes" => hashes},
             "code" => %{"sha" => <<_::binary-size(40)>>},
             "model" => %{"id" => "qwen/qwen3-embedding-8b"},
             "dimensions" => %{"requested" => 1024, "mode" => "requested"},
             "preparation" => %{"query_instruction" => "Instruct: " <> _},
             "memory" => %{"baseline_rss_kib" => baseline, "peak_rss_kib" => peak},
             "latency" => %{"query_ms" => [_ | _] = query_ms},
             "long_inputs" => [_, _, _, _, _]
           } = report

    assert hashes == fixtures.hashes
    assert peak >= baseline
    assert length(query_ms) == 30
    assert Enum.all?(report["gates"], & &1["passed"])

    # Rankings and recall recompute from the retained scores.
    for query <- report["queries"] do
      scores = report["scores"]["bounded"][query["id"]]

      ranked =
        scores |> Enum.sort_by(fn {id, score} -> {-score, id} end) |> Enum.map(&elem(&1, 0))

      assert Enum.take(ranked, 5) == query["top_k"]
      assert SearchProbe.recall(ranked, query["relevant"], 5) == query["recall"]
    end

    # Queries that match nothing relevant fail the recall gates and exit nonzero.
    misses = stub_provider(fixtures, fn _conn, _body -> :pass end, miss_queries: true)

    assert {1, printed} =
             main(["--real", "--output", output],
               mode: :real,
               api_key: @secret,
               req_options: [plug: misses]
             )

    assert printed =~ "failed"
    failed = output |> File.read!() |> Jason.decode!()
    assert failed["status"] == "failed"

    assert %{"macro_recall_at_k" => false, "every_query_top_k_hit" => false} =
             Map.new(failed["gates"], &{&1["name"], &1["passed"]})
  end

  test "keeps the first 1024 of 4096 values only when dimensions are ignored or rejected", %{
    fixtures: fixtures,
    tmp_dir: tmp_dir
  } do
    for {dimensions, mode, extra_requests} <- [
          {:ignore, "ignored", 0},
          {:reject, "unsupported", 1}
        ] do
      plug = stub_provider(fixtures, fn _conn, _body -> :pass end, dimensions: dimensions)
      report = run!(fixtures, plug, tmp_dir)

      assert %{"status" => "passed", "dimensions" => dims} = report
      assert %{"mode" => ^mode, "returned_lengths" => [4096]} = dims
      rejected = Enum.count(report["requests"], &(&1["outcome"] == "dimensions_rejected"))
      assert rejected == extra_requests
    end

    # A 400 stays provisional: when the retry without dimensions also fails, nothing claims
    # the parameter was rejected.
    both_fail =
      stub_provider(fixtures, fn
        %{request_path: "/api/v1/embeddings"} = conn, body ->
          status = if body =~ ~s("dimensions"), do: 400, else: 503
          {:respond, Plug.Conn.send_resp(conn, status, "nope")}

        _conn, _body ->
          :pass
      end)

    report = run!(fixtures, both_fail, tmp_dir)
    assert %{"status" => "failed", "error" => "http_503"} = report
    assert %{"mode" => nil, "returned_lengths" => []} = report["dimensions"]

    assert ["ok", "ok", "http_400", "http_503"] = Enum.map(report["requests"], & &1["outcome"])
  end

  test "accepts only the requested model from the pinned upstream", %{
    fixtures: fixtures,
    tmp_dir: tmp_dir
  } do
    canonical = run!(fixtures, stub_provider(fixtures, fn _, _ -> :pass end), tmp_dir)
    assert canonical["status"] == "passed"

    assert %{
             "passed" => true,
             "value" => %{"models" => ["Qwen/Qwen3-Embedding-8B"], "upstreams" => ["DeepInfra"]}
           } = Enum.find(canonical["gates"], &(&1["name"] == "candidate_identity"))

    for {identity, error} <- [
          {%{"model" => "qwen/qwen3-embedding-4b", "provider" => "DeepInfra"}, "model_mismatch"},
          {%{"model" => "Qwen/Qwen3-Embedding-8B", "provider" => "SiliconFlow"},
           "upstream_mismatch"},
          {%{"model" => "Qwen/Qwen3-Embedding-8B"}, "missing_identity"},
          {%{}, "missing_identity"}
        ] do
      plug = stub_provider(fixtures, fn _, _ -> :pass end, identity: identity)
      report = run!(fixtures, plug, tmp_dir)

      assert %{"status" => "failed", "blocker" => nil, "error" => ^error} = report
      # The first mismatching response stops the run.
      assert [_endpoints, _key, %{"phase" => "document", "outcome" => ^error}] =
               report["requests"]
    end
  end

  test "enforces a hard total deadline on each request", %{fixtures: fixtures, tmp_dir: tmp_dir} do
    test = self()

    slow = fn conn ->
      Process.sleep(1_000)
      send(test, :late_response)
      Req.Test.json(conn, %{})
    end

    fast = respond(fn _ -> [vector([1.0], 1024)] end)
    deadline = %{provider(slow) | timeout_ms: 100}

    {elapsed_us, result} = :timer.tc(fn -> SearchProbe.embed(["x"], deadline) end)
    assert result == {:error, :timeout}
    assert elapsed_us < 500_000
    assert {:ok, _} = SearchProbe.embed(["x"], %{provider(fast) | timeout_ms: 100})

    # In a run, the first query past its deadline stops the probe; nothing continues.
    short = put_in(fixtures.gate["gate"]["query_deadline_ms"], 100)

    plug =
      stub_provider(short, fn conn, body ->
        if body =~ "Instruct:", do: {:respond, slow.(conn)}, else: :pass
      end)

    report = run!(short, plug, tmp_dir)
    assert %{"status" => "failed", "blocker" => nil, "error" => "timeout"} = report

    assert %{"phase" => "query", "outcome" => "timeout", "elapsed_ms" => ms} =
             List.last(report["requests"])

    assert ms < 500
    assert Enum.count(report["requests"], &(&1["phase"] == "query")) == 1
    refute_receive :late_response, 1_200
  end

  # -- helpers --

  defp main(argv, opts) do
    ExUnit.CaptureIO.with_io(fn -> SearchProbe.main(argv, opts) end)
  end

  defp run!(fixtures, plug, tmp_dir) do
    output = Path.join(tmp_dir, "report.json")

    {_status, _} =
      main(["--real", "--output", output],
        mode: :real,
        api_key: @secret,
        fixtures: fixtures,
        req_options: [plug: plug]
      )

    output |> File.read!() |> Jason.decode!()
  end

  defp collect_http(acc \\ []) do
    receive do
      {:http, method, path, body} -> collect_http([{method, path, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp provider(plug) do
    %{
      api_key: @secret,
      base_url: "https://provider.test/api/v1",
      model: "qwen/qwen3-embedding-8b",
      routing: %{},
      upstream: "deepinfra",
      dimensions: 1024,
      send_dimensions: true,
      expected_length: nil,
      timeout_ms: 1_000,
      req_options: [plug: plug]
    }
  end

  defp respond(data_fun) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"input" => inputs} = Jason.decode!(body)
      Req.Test.json(conn, Map.put(@identity, "data", data_fun.(inputs)))
    end
  end

  defp vector(prefix, size), do: %{"index" => 0, "embedding" => vector_values(prefix, size)}

  defp vector_values(prefix, size), do: prefix ++ List.duplicate(0.0, size - length(prefix))

  defp norm(vec), do: vec |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

  # A provider double that knows the fixtures: each relevant document and its queries share
  # one axis, so the gate passes unless `miss_queries` points queries at an unused axis.
  # `hook` sees every request and returns `:pass` or `{:respond, conn}`.
  defp stub_provider(fixtures, hook, opts \\ []) do
    %{corpus: corpus, queries: queries, gate: gate} = fixtures

    axes =
      for {query, axis} <- Enum.with_index(queries), id <- query["relevant"], reduce: %{} do
        acc -> Map.put_new(acc, id, axis)
      end

    document_axes =
      for doc <- corpus, reduce: %{} do
        acc ->
          axis = Map.get(axes, doc["id"], 20 + :erlang.phash2(doc["id"], 500))
          prepared = SearchProbe.prepare_document(doc, gate)

          acc
          |> Map.put(prepared.text, axis)
          |> Map.put(SearchProbe.document_text(doc), axis)
      end

    query_axes =
      for {query, axis} <- Enum.with_index(queries), into: %{} do
        {:ok, text} = SearchProbe.prepare_query(query["text"], gate)
        {text, if(opts[:miss_queries], do: 1000, else: axis)}
      end

    text_axes = Map.merge(document_axes, query_axes)

    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case hook.(conn, body) do
        {:respond, conn} -> conn
        :pass -> serve(conn, body, text_axes, opts)
      end
    end
  end

  defp serve(%{method: "GET", request_path: "/api/v1/models/" <> _} = conn, _body, _axes, _opts) do
    Req.Test.json(conn, %{
      "data" => %{
        "endpoints" => [
          %{
            "tag" => "deepinfra",
            "provider_name" => "DeepInfra",
            "context_length" => 32_768,
            "status" => 0,
            "pricing" => %{"prompt" => "0.00000001"}
          }
        ]
      }
    })
  end

  defp serve(%{method: "GET", request_path: "/api/v1/key"} = conn, _body, _axes, _opts) do
    Req.Test.json(conn, %{
      "data" => %{"label" => "sentinel-label", "limit" => nil, "is_free_tier" => false}
    })
  end

  defp serve(%{method: "POST", request_path: "/api/v1/embeddings"} = conn, body, axes, opts) do
    request = Jason.decode!(body)
    identity = Keyword.get(opts, :identity, @identity)

    case {Keyword.get(opts, :dimensions, :honor), request} do
      {:reject, %{"dimensions" => _}} ->
        Plug.Conn.send_resp(conn, 400, "unsupported")

      {:honor, %{"dimensions" => 1024}} ->
        embeddings(conn, body, request["input"], axes, 1024, identity)

      {_dims, _request} ->
        embeddings(conn, body, request["input"], axes, 4096, identity)
    end
  end

  defp embeddings(conn, body, inputs, axes, size, identity) do
    data =
      inputs
      |> Enum.with_index()
      |> Enum.map(fn {input, index} ->
        axis = Map.fetch!(axes, input)

        values =
          0.0 |> List.duplicate(size) |> List.replace_at(axis, 2.0) |> List.replace_at(1023, 0.1)

        %{"index" => index, "embedding" => values}
      end)

    Req.Test.json(
      conn,
      Map.merge(identity, %{
        "data" => data,
        "usage" => %{"prompt_tokens" => div(byte_size(body), 4), "cost" => 1.0e-7}
      })
    )
  end
end
