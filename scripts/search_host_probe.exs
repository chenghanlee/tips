# Measures Nebius as the search embedding host for #363, once, before the host is kept.
#
#     MIX_ENV=dev mix run --no-start scripts/search_host_probe.exs --check
#     TIPS_REAL_PROVIDERS=1 MIX_ENV=dev mix run --no-start scripts/search_host_probe.exs --report PATH --vectors PATH
#
# --check prints the plan and the estimate without calling the provider. The real run needs
# TIPS_REAL_PROVIDERS=1, a clean checkout and the authorization on #363. It sends every request
# through Tips.Content.Search.EmbeddingProvider, pinned to Nebius in the same commit as this plan:
#
#   1. The 40 eligible corpus documents of test/fixtures/search_probe, in corpus order.
#   2. The ten gate queries, after the gate's query instruction.
#   3. A wait of 15 minutes with no request, then q01 once more: the cold request.
#
# 51 requests, one at a time. Each has the provider's 30-second deadline, so a slow answer is
# measured rather than cut off. The run stops at the first error and never retries.
#
# Pass rule, on the time around each EmbeddingProvider call: every request answered by Nebius;
# every document within 30,000 ms; every query, the cold one included, within the 4,500 ms query
# budget. Finch's duration of each request is recorded beside it.
#
# The report goes to --report. The document and query vectors go to --vectors in the format
# Tips.SearchGateVectors reads; on a pass they replace test/fixtures/search_probe/vectors-60.json.
defmodule SearchHostProbeScript do
  alias Tips.Content.Search.EmbeddingProvider
  alias Tips.{Repo, SearchGate}

  @issue "https://github.com/chenghanlee/tips/issues/363"
  @host "Nebius"
  @price_source "test/fixtures/search_probe/evidence/60-integrated-run-4.json"
  @max_requests 60
  @max_cost_usd 0.01
  @document_budget_ms 30_000
  @query_budget_ms 4_500
  @quiet_ms 15 * 60_000
  @cold_query "q01"
  @tokens_per_input 8
  @query_instruction "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:"

  def main(argv) do
    case OptionParser.parse(argv, strict: [check: :boolean, report: :string, vectors: :string]) do
      {[check: true], [], []} -> check()
      {opts, [], []} when length(opts) == 2 -> real(opts[:report], opts[:vectors])
      _invalid -> refuse("usage: --check | --report PATH --vectors PATH")
    end
  end

  defp check do
    with {:ok, plan} <- plan() do
      IO.puts(JSON.encode!(Map.drop(plan, [:documents, :queries])))
      0
    end
  end

  defp real(report, vectors) when is_binary(report) and is_binary(vectors) do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {dirty, 0} = System.cmd("git", ["status", "--porcelain"])

    cond do
      System.get_env("TIPS_REAL_PROVIDERS") != "1" -> refuse("set TIPS_REAL_PROVIDERS=1")
      File.exists?(report) -> refuse("#{report} exists")
      File.exists?(vectors) -> refuse("#{vectors} exists")
      dirty != "" -> refuse("the checkout has uncommitted changes")
      true -> with {:ok, plan} <- plan(), do: run(plan, report, vectors, String.trim(sha))
    end
  end

  defp real(_report, _vectors), do: refuse("usage: --check | --report PATH --vectors PATH")

  defp plan do
    if Mix.env() != :dev do
      refuse("run with MIX_ENV=dev")
    else
      start()
      {:ok, fixtures} = SearchGate.load()
      documents = documents(fixtures.corpus)
      eligible = fixtures.gate["corpus_setup"]["eligible_documents"]
      queries = fixtures.queries ++ [Enum.find(fixtures.queries, &(&1["id"] == @cold_query))]

      price =
        (@price_source |> File.read!() |> JSON.decode!())["preflight"]["listed_endpoints"]
        |> Enum.find(&(&1["provider"] == @host))
        |> Map.fetch!("prompt_price_usd_per_token")

      tokens =
        Enum.sum_by(documents, &(byte_size(&1.text) + @tokens_per_input)) +
          Enum.sum_by(queries, &(byte_size(@query_instruction <> &1["text"]) + @tokens_per_input))

      plan = %{
        host: @host,
        sequence:
          "#{length(documents)} documents, #{length(fixtures.queries)} queries, " <>
            "#{div(@quiet_ms, 60_000)} minutes with no request, then #{@cold_query} again",
        requests: length(documents) + length(queries),
        deadline_ms: 30_000,
        retries: 0,
        pass_rule: %{
          measure: "milliseconds around each EmbeddingProvider call",
          answered_by: @host,
          document_ms: @document_budget_ms,
          query_ms: @query_budget_ms,
          quiet_ms_before_cold_query: @quiet_ms
        },
        budget: %{max_requests: @max_requests, max_cost_usd: @max_cost_usd},
        estimate: %{
          price_usd_per_token: price,
          price_source: "#{@price_source} preflight listing, provider #{@host}",
          max_input_tokens: tokens,
          estimated_max_cost_usd: tokens * price
        },
        fixture_hashes: Map.take(fixtures.hashes, ["corpus.json", "queries.json"]),
        documents: documents,
        queries: queries
      }

      cond do
        length(documents) != eligible -> refuse("#{length(documents)} documents, not #{eligible}")
        plan.requests > @max_requests -> refuse("over the request budget")
        tokens * price > @max_cost_usd -> refuse("over the cost budget")
        true -> {:ok, plan}
      end
    end
  end

  defp start do
    # Only the requests below may call the provider: no cron scan, no queues.
    oban = Application.fetch_env!(:tips, Oban)
    Application.put_env(:tips, Oban, Keyword.merge(oban, queues: false, plugins: false))
    Logger.configure(level: :info)
    {:ok, _apps} = Application.ensure_all_started(:tips)
  end

  # The search text of each document the scan would embed: published tips and
  # reviews of published tips. The corpus is seeded in a transaction that is
  # rolled back, so the database is left as it was.
  defp documents(corpus) do
    published = for %{"kind" => "tip", "state" => "published", "id" => id} <- corpus, do: id

    {:error, documents} =
      Repo.transact(fn ->
        ids = SearchGate.seed_corpus(corpus)

        Repo.rollback(
          for %{"id" => id} = doc <- corpus,
              (doc["kind"] == "tip" and id in published) or
                (doc["kind"] == "review" and doc["parent_id"] in published) do
            {kind, row} = ids[id]
            %{id: id, kind: Atom.to_string(kind), text: search_text(kind, row)}
          end
        )
      end)

    documents
  end

  defp search_text(:tip, id),
    do:
      Repo.query!("SELECT search_text FROM tip_search WHERE tip_id = $1", [id]).rows
      |> hd()
      |> hd()

  defp search_text(:review, id),
    do:
      Repo.query!("SELECT search_text FROM review_search WHERE review_id = $1", [id]).rows
      |> hd()
      |> hd()

  defp run(plan, report_path, vectors_path, sha) do
    :real = Tips.ProviderConfig.mode()

    :telemetry.attach(
      :search_host_probe,
      [:finch, :request, :stop],
      &__MODULE__.handle_finch/4,
      self()
    )

    client = EmbeddingProvider.client!()
    started_at = DateTime.utc_now() |> DateTime.to_iso8601()

    steps =
      Enum.map(plan.documents, &{:document, &1.id, &1.text}) ++
        Enum.map(Enum.drop(plan.queries, -1), &{:query, &1["id"], &1["text"]}) ++
        [:wait, {:cold_query, @cold_query, List.last(plan.queries)["text"]}]

    {results, stopped} =
      Enum.reduce_while(steps, {[], nil}, fn
        :wait, {results, nil} ->
          Process.sleep(@quiet_ms)
          {:cont, {results, nil}}

        step, {results, nil} ->
          result = embed(client, step)
          stopped = if result.result != "ok", do: "#{result.id}: #{result.result}"
          {if(stopped, do: :halt, else: :cont), {[result | results], stopped}}
      end)

    results = Enum.reverse(results)
    gates = gates(plan, results)
    status = if stopped == nil and Enum.all?(gates, & &1.passed), do: :passed, else: :failed

    report = %{
      issue: @issue,
      status: status,
      stopped: stopped,
      code: %{sha: sha, dirty: false},
      started_at: started_at,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      plan: Map.drop(plan, [:documents, :queries]),
      requests: Enum.map(results, &Map.drop(&1, [:vector])),
      cold_gap_ms: cold_gap(results),
      usage: usage(results),
      gates: gates
    }

    File.write!(report_path, JSON.encode!(report))
    write_vectors(vectors_path, plan, results, report_path, sha)
    IO.puts("#{status}: #{report_path}")
    if status == :passed, do: 0, else: 1
  end

  defp embed(client, {kind, id, text}) do
    started_at = DateTime.utc_now() |> DateTime.to_iso8601()
    started = System.monotonic_time(:millisecond)

    result =
      if kind == :document,
        do: EmbeddingProvider.embed_document(client, text),
        else: EmbeddingProvider.embed_query(client, text)

    ended = System.monotonic_time(:millisecond)

    finch =
      receive do
        {:request, record} -> Map.delete(record, :input)
      after
        1_000 -> nil
      end

    %{
      kind: kind,
      id: id,
      started_at: started_at,
      started_ms: started,
      ended_ms: ended,
      ms: ended - started,
      result: if(match?({:ok, _vector}, result), do: "ok", else: inspect(elem(result, 1))),
      vector: if(match?({:ok, _vector}, result), do: elem(result, 1)),
      finch: finch
    }
  end

  defp gates(plan, results) do
    by_kind = &Enum.filter(results, fn result -> result.kind in &1 end)
    documents = by_kind.([:document])
    queries = by_kind.([:query, :cold_query])
    gap = cold_gap(results)

    [
      gate("all requests answered", length(results) == plan.requests, length(results)),
      gate(
        "answered by #{@host}",
        Enum.all?(results, &(&1.result == "ok" and &1.finch[:provider] == @host)),
        results |> Enum.map(& &1.finch[:provider]) |> Enum.frequencies()
      ),
      gate(
        "documents within #{@document_budget_ms} ms",
        Enum.all?(documents, &(&1.ms <= @document_budget_ms)),
        documents |> Enum.map(& &1.ms) |> Enum.max(fn -> nil end)
      ),
      gate(
        "queries within #{@query_budget_ms} ms",
        Enum.all?(queries, &(&1.ms <= @query_budget_ms)),
        queries |> Enum.map(& &1.ms) |> Enum.max(fn -> nil end)
      ),
      gate("cold query after #{@quiet_ms} ms quiet", is_integer(gap) and gap >= @quiet_ms, gap)
    ]
  end

  defp gate(rule, passed, measured), do: %{rule: rule, passed: passed, measured: measured}

  defp cold_gap(results) do
    case Enum.split_with(results, &(&1.kind != :cold_query)) do
      {[_ | _] = before, [cold]} -> cold.started_ms - List.last(before).ended_ms
      _no_cold_query -> nil
    end
  end

  defp usage(results) do
    records = results |> Enum.map(& &1.finch) |> Enum.reject(&is_nil/1)

    %{
      requests: length(results),
      unrecorded_requests: length(results) - length(records),
      prompt_tokens:
        records |> Enum.map(& &1.prompt_tokens) |> Enum.filter(&is_integer/1) |> Enum.sum(),
      cost_usd: records |> Enum.map(& &1.cost_usd) |> Enum.filter(&is_number/1) |> Enum.sum()
    }
  end

  defp write_vectors(path, plan, results, report_path, sha) do
    vectors =
      Map.new(for %{vector: v} = r <- results, v != nil, r.kind != :cold_query, do: {r.id, v})

    documents =
      for doc <- plan.documents, Map.has_key?(vectors, doc.id) do
        %{
          id: doc.id,
          kind: doc.kind,
          search_text_sha256: sha256(doc.text),
          embedding: vectors[doc.id]
        }
      end

    queries =
      for query <- Enum.drop(plan.queries, -1),
          Map.has_key?(vectors, query["id"]),
          do: %{id: query["id"], embedding: vectors[query["id"]]}

    meta = %{
      issue: @issue,
      report: report_path,
      code: %{sha: sha},
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      model: "qwen/qwen3-embedding-8b",
      upstream: @host,
      dimensions: 1024,
      fixture_hashes: plan.fixture_hashes,
      embedding: "pgvector text of Tips.Content.Search.EmbeddingProvider's vector",
      query_instruction: @query_instruction
    }

    lines = &Enum.map_join(&1, ",\n", fn entry -> JSON.encode!(entry) end)

    File.write!(path, [
      ~s({"meta":),
      JSON.encode!(meta),
      ~s(,\n"documents":[\n),
      lines.(documents),
      ~s(\n],\n"queries":[\n),
      lines.(queries),
      "\n]}\n"
    ])
  end

  @doc false
  def handle_finch(
        _event,
        %{duration: duration},
        %{request: %{host: "openrouter.ai"} = request} = metadata,
        pid
      ) do
    {status, body} =
      case metadata.result do
        {:ok, {_req, {status, _headers, body, _trailers}}} -> {status, IO.iodata_to_binary(body)}
        {:ok, %{status: status, body: body}} -> {status, body}
        {:error, _exception} -> {nil, nil}
      end

    ms = System.convert_time_unit(duration, :native, :millisecond)
    send(pid, {:request, SearchGate.request_record(request.path, nil, status, body, ms)})
  end

  def handle_finch(_event, _measurements, _metadata, _pid), do: :ok

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp refuse(message) do
    IO.puts(:stderr, message)
    2
  end
end

System.halt(SearchHostProbeScript.main(System.argv()))
