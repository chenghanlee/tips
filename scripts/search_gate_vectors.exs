# Writes the frozen vectors of #348: the 40 document vectors of #60 gate run 3, read from
# the development database that run left, and one query vector per gate query.
#
#     TIPS_REAL_PROVIDERS=1 MIX_ENV=dev mix run --no-start scripts/search_gate_vectors.exs --output PATH
#
# --check matches the documents and prints the estimate without calling the provider.
# Documents are never embedded again. Each query makes one OpenRouter request through
# Tips.Content.Search.EmbeddingProvider; the script stops at the first provider error and
# never retries.
#
#     TIPS_REAL_PROVIDERS=1 MIX_ENV=dev mix run --no-start scripts/search_gate_vectors.exs --add-missing PATH
#
# --add-missing embeds the queries PATH lacks, under the second authorization: one retry per
# query after an error, and a stop when a query fails twice. Tests load the result with
# Tips.SearchGateVectors.
defmodule SearchGateVectorsScript do
  import Ecto.Query

  alias Tips.Content.Search.EmbeddingProvider
  alias Tips.{Repo, SearchGate}

  @authorization "https://github.com/chenghanlee/tips/issues/60#issuecomment-6022030147"
  @run "test/fixtures/search_probe/evidence/60-integrated-run-3.json"
  @second_authorization "https://github.com/chenghanlee/tips/issues/348#issuecomment-6022334989"
  @max_requests 12
  @max_added_requests 10
  @max_cost_usd 0.01
  @tokens_per_input 8
  @query_instruction "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:"

  def main(argv) do
    case OptionParser.parse(argv,
           strict: [output: :string, check: :boolean, add_missing: :string]
         ) do
      {[add_missing: path], [], []} ->
        add_missing(path)

      {[output: output], [], []} ->
        check(output, :embed)

      {[output: output, check: true], [], []} ->
        check(output, :check)

      {[check: true, output: output], [], []} ->
        check(output, :check)

      _invalid ->
        refuse("usage: --output PATH [--check] | --add-missing PATH")
    end
  end

  defp check(output, action) do
    cond do
      Mix.env() != :dev -> refuse("run with MIX_ENV=dev")
      System.get_env("TIPS_REAL_PROVIDERS") != "1" -> refuse("set TIPS_REAL_PROVIDERS=1")
      File.exists?(output) -> refuse("#{output} exists")
      true -> run(output, action)
    end
  end

  defp start do
    # Only the query requests below may call the provider: no cron scan, no queues.
    oban = Application.fetch_env!(:tips, Oban)
    Application.put_env(:tips, Oban, Keyword.merge(oban, queues: false, plugins: false))
    Logger.configure(level: :info)
    {:ok, _apps} = Application.ensure_all_started(:tips)
    :real = Tips.ProviderConfig.mode()
  end

  defp run(output, action) do
    start()
    {:ok, fixtures} = SearchGate.load()
    documents = documents(fixtures.corpus)
    run = @run |> File.read!() |> JSON.decode!()
    price = run["preflight"]["endpoint"]["prompt_price_usd_per_token"]

    tokens =
      Enum.sum_by(
        fixtures.queries,
        &(byte_size(@query_instruction <> &1["text"]) + @tokens_per_input)
      )

    estimate = tokens * price
    IO.puts("#{length(fixtures.queries)} requests, at most #{tokens} tokens, US$#{estimate}")

    cond do
      length(fixtures.queries) > @max_requests or estimate > @max_cost_usd ->
        refuse("over the authorized budget")

      action == :check ->
        IO.puts("#{length(documents)} documents matched; no provider request made")
        0

      true ->
        embed(output, fixtures, documents, run, %{
          price_usd_per_token: price,
          price_source: "#{@run} preflight",
          max_input_tokens: tokens,
          estimated_max_cost_usd: estimate
        })
    end
  end

  # Each corpus document's search text comes from seeding the corpus again in a
  # transaction that is rolled back, so run 3's rows are matched by their text.
  defp documents(corpus) do
    {:error, seeded} =
      Repo.transact(fn ->
        ids = SearchGate.seed_corpus(corpus)
        Repo.rollback(for {id, row} <- ids, do: {sha256(search_text(row)), id})
      end)

    # Two corpus documents with the same text could not be told apart.
    true = seeded |> Enum.uniq_by(&elem(&1, 0)) |> length() == length(seeded)
    seeded = Map.new(seeded)

    embedded =
      Repo.all(
        from(s in "tip_search",
          where: not is_nil(s.embedding),
          select: {"tip", s.search_text, fragment("?::text", s.embedding)}
        )
      ) ++
        Repo.all(
          from(s in "review_search",
            where: not is_nil(s.embedding),
            select: {"review", s.search_text, fragment("?::text", s.embedding)}
          )
        )

    order = corpus |> Enum.with_index() |> Map.new(fn {doc, i} -> {doc["id"], i} end)

    documents =
      embedded
      |> Enum.map(fn {kind, text, embedding} ->
        sha = sha256(text)

        %{
          id: Map.fetch!(seeded, sha),
          kind: kind,
          search_text_sha256: sha,
          embedding: embedding
        }
      end)
      |> Enum.sort_by(&order[&1.id])

    40 = documents |> Enum.uniq_by(& &1.id) |> length()
    documents
  end

  defp search_text({:tip, id}),
    do: Repo.one!(from(s in "tip_search", where: s.tip_id == ^id, select: s.search_text))

  defp search_text({:review, id}),
    do: Repo.one!(from(s in "review_search", where: s.review_id == ^id, select: s.search_text))

  defp embed(output, fixtures, documents, run, estimate) do
    :telemetry.attach(
      :search_gate_vectors,
      [:finch, :request, :stop],
      &__MODULE__.handle_finch/4,
      self()
    )

    {queries, _attempts, stopped} = embed_queries(fixtures.queries, 0)
    requests = requests([])

    meta = %{
      issue: "https://github.com/chenghanlee/tips/issues/348",
      authorization: @authorization,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      model: "qwen/qwen3-embedding-8b",
      upstream: "DeepInfra",
      dimensions: 1024,
      fixture_hashes: Map.take(fixtures.hashes, ["corpus.json", "queries.json"]),
      documents: %{
        source: "#{@run}: the development database the run left; not embedded again",
        code: run["code"],
        versions: run["versions"],
        embedding: "pgvector text of the stored vector"
      },
      queries: %{
        instruction: @query_instruction,
        embedding:
          "pgvector text of Tips.Content.Search.EmbeddingProvider.embed_query/2's vector",
        estimate: estimate,
        stopped: stopped,
        requests: requests,
        usage: usage(requests)
      }
    }

    write(output, meta, documents, queries)

    failed = Enum.count(requests, &(&1.outcome != "ok"))

    IO.puts(
      "#{length(queries)} queries, #{length(requests)} requests, #{failed} failed: #{output}"
    )

    if stopped == nil and failed == 0 and length(queries) == length(fixtures.queries),
      do: 0,
      else: 1
  end

  # The second authorization: embed only the queries `path` lacks, retrying each
  # once after an error, and stop when one fails twice.
  defp add_missing(path) do
    cond do
      Mix.env() != :dev -> refuse("run with MIX_ENV=dev")
      System.get_env("TIPS_REAL_PROVIDERS") != "1" -> refuse("set TIPS_REAL_PROVIDERS=1")
      not File.exists?(path) -> refuse("#{path} does not exist")
      true -> add_missing(path, path |> File.read!() |> JSON.decode!())
    end
  end

  defp add_missing(path, %{"meta" => meta, "documents" => documents, "queries" => queries}) do
    start()
    {:ok, fixtures} = SearchGate.load()
    true = meta["fixture_hashes"] == Map.take(fixtures.hashes, ["corpus.json", "queries.json"])
    have = MapSet.new(queries, & &1["id"])
    missing = Enum.reject(fixtures.queries, &(&1["id"] in have))

    price =
      (@run
       |> File.read!()
       |> JSON.decode!())["preflight"]["endpoint"]["prompt_price_usd_per_token"]

    requests = 2 * length(missing)

    tokens =
      2 * Enum.sum_by(missing, &(byte_size(@query_instruction <> &1["text"]) + @tokens_per_input))

    estimate = tokens * price

    IO.puts(
      "#{length(missing)} queries, at most #{requests} requests and #{tokens} tokens, US$#{estimate}"
    )

    if requests > @max_added_requests or estimate > @max_cost_usd do
      refuse("over the authorized budget")
    else
      :telemetry.attach(
        :search_gate_vectors,
        [:finch, :request, :stop],
        &__MODULE__.handle_finch/4,
        self()
      )

      {added, attempts, stopped} = embed_queries(missing, 1)
      recorded = requests([])
      order = fixtures.queries |> Enum.with_index() |> Map.new(fn {q, i} -> {q["id"], i} end)
      queries = Enum.sort_by(queries ++ JSON.decode!(JSON.encode!(added)), &order[&1["id"]])

      meta =
        meta
        |> put_in(["queries", "unrecorded_requests"], %{
          count: 1,
          note: "q06's request was killed at the 30-second deadline before Finch recorded it"
        })
        |> Map.put("queries_added", %{
          authorization: @second_authorization,
          retries_per_query: 1,
          estimate: %{
            price_usd_per_token: price,
            max_requests: requests,
            max_input_tokens: tokens,
            estimated_max_cost_usd: estimate
          },
          attempts: attempts,
          stopped: stopped,
          requests: recorded,
          usage: usage(recorded)
        })
        |> Map.put(
          "missing_queries",
          for(q <- fixtures.queries, q["id"] not in Enum.map(queries, & &1["id"]), do: q["id"])
        )

      write(path, meta, documents, queries)

      IO.puts(
        "#{length(added)} added, #{length(attempts)} attempts, missing #{inspect(meta["missing_queries"])}: #{path}"
      )

      if stopped == nil, do: 0, else: 1
    end
  end

  # Embeds each query, retrying it up to `retries` times after an error. Stops at
  # a query that fails every attempt. Every attempt counts as one request.
  defp embed_queries(queries, retries) do
    client = EmbeddingProvider.client!()

    {vectors, attempts, stopped} =
      Enum.reduce_while(queries, {[], [], nil}, fn query, {vectors, attempts, nil} ->
        case attempt(client, query, retries, attempts) do
          {{:ok, literal}, attempts} ->
            {:cont, {[%{id: query["id"], embedding: literal} | vectors], attempts, nil}}

          {{:error, reason}, attempts} ->
            {:halt, {vectors, attempts, %{query: query["id"], reason: inspect(reason)}}}
        end
      end)

    {Enum.reverse(vectors), Enum.reverse(attempts), stopped}
  end

  defp attempt(client, %{"id" => id, "text" => text} = query, retries, attempts) do
    started = System.monotonic_time(:millisecond)
    result = EmbeddingProvider.embed_query(client, text)

    attempts = [
      %{
        query: id,
        result: if(match?({:ok, _vector}, result), do: "ok", else: inspect(elem(result, 1))),
        ms: System.monotonic_time(:millisecond) - started
      }
      | attempts
    ]

    case result do
      {:error, _reason} when retries > 0 -> attempt(client, query, retries - 1, attempts)
      result -> {result, attempts}
    end
  end

  defp usage(requests) do
    %{
      requests: length(requests),
      prompt_tokens:
        requests |> Enum.map(& &1.prompt_tokens) |> Enum.filter(&is_integer/1) |> Enum.sum(),
      cost_usd: requests |> Enum.map(& &1.cost_usd) |> Enum.filter(&is_number/1) |> Enum.sum()
    }
  end

  defp write(path, meta, documents, queries) do
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

  defp requests(acc) do
    receive do
      {:request, record} -> requests([Map.delete(record, :input) | acc])
    after
      1_000 -> Enum.reverse(acc)
    end
  end

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp refuse(message) do
    IO.puts(:stderr, message)
    2
  end
end

System.halt(SearchGateVectorsScript.main(System.argv()))
