# Writes the frozen vectors of #365: one vector for each of the 40 eligible corpus documents
# and the ten gate queries, from the configured embedding runtime.
#
#     MIX_ENV=dev mix run --no-start scripts/search_gate_vectors.exs --check
#     TIPS_REAL_PROVIDERS=1 MIX_ENV=dev mix run --no-start scripts/search_gate_vectors.exs --output PATH
#
# --check prints the plan and the estimate without calling the provider. The real run needs
# TIPS_REAL_PROVIDERS=1, a clean checkout and the authorization on #365. It sends every request
# through Tips.Content.Search.EmbeddingProvider, one at a time: the documents in corpus order,
# then the queries. A request that reaches its 30-second deadline is retried once; any other
# error, or a second failure, stops the run.
#
# The output has the format Tips.SearchGateVectors reads. Its meta records each request's time,
# answering host and cost. On success it replaces test/fixtures/search_probe/vectors-60.json.
defmodule SearchGateVectorsScript do
  alias Tips.Content.Search.EmbeddingProvider
  alias Tips.Content.Search.EmbeddingProvider.OpenRouter
  alias Tips.{Repo, SearchGate}

  @issue "https://github.com/chenghanlee/tips/issues/365"
  @price_source "test/fixtures/search_probe/evidence/60-integrated-run-4.json"
  @max_requests 60
  @max_cost_usd 0.01
  @tokens_per_input 8

  def main(argv) do
    case OptionParser.parse(argv, strict: [check: :boolean, output: :string]) do
      {[check: true], [], []} -> check()
      {[output: output], [], []} -> real(output)
      _invalid -> refuse("usage: --check | --output PATH")
    end
  end

  defp check do
    with {:ok, plan} <- plan() do
      IO.puts(JSON.encode!(Map.drop(plan, [:documents, :queries])))
      0
    end
  end

  defp real(output) do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {dirty, 0} = System.cmd("git", ["status", "--porcelain"])

    cond do
      System.get_env("TIPS_REAL_PROVIDERS") != "1" -> refuse("set TIPS_REAL_PROVIDERS=1")
      File.exists?(output) -> refuse("#{output} exists")
      dirty != "" -> refuse("the checkout has uncommitted changes")
      true -> with {:ok, plan} <- plan(), do: run(plan, output, String.trim(sha))
    end
  end

  defp plan do
    if Mix.env() != :dev do
      refuse("run with MIX_ENV=dev")
    else
      start()
      {:ok, fixtures} = SearchGate.load()
      runtime = OpenRouter.runtime()
      documents = documents(fixtures.corpus)
      eligible = fixtures.gate["corpus_setup"]["eligible_documents"]

      price =
        (@price_source |> File.read!() |> JSON.decode!())["preflight"]["listed_endpoints"]
        |> Enum.find(&(&1["provider"] == runtime.upstream))
        |> Map.fetch!("prompt_price_usd_per_token")

      # Every request may be sent twice.
      tokens =
        2 *
          (Enum.sum_by(documents, &(byte_size(&1.text) + @tokens_per_input)) +
             Enum.sum_by(
               fixtures.queries,
               &(byte_size(runtime.query_instruction <> &1["text"]) + @tokens_per_input)
             ))

      plan = %{
        runtime: runtime,
        requests: length(documents) + length(fixtures.queries),
        deadline_ms: 30_000,
        retries: "one, after a deadline",
        budget: %{max_requests: @max_requests, max_cost_usd: @max_cost_usd},
        estimate: %{
          price_usd_per_token: price,
          price_source: "#{@price_source} preflight listing, provider #{runtime.upstream}",
          max_input_tokens: tokens,
          estimated_max_cost_usd: tokens * price
        },
        fixture_hashes: Map.take(fixtures.hashes, ["corpus.json", "queries.json"]),
        documents: documents,
        queries: fixtures.queries
      }

      cond do
        length(documents) != eligible -> refuse("#{length(documents)} documents, not #{eligible}")
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

  defp search_text(kind, id) do
    %{rows: [[text]]} =
      Repo.query!("SELECT search_text FROM #{kind}_search WHERE #{kind}_id = $1", [id])

    text
  end

  defp run(plan, output, sha) do
    :real = Tips.ProviderConfig.mode()

    :telemetry.attach(
      :search_gate_vectors,
      [:finch, :request, :stop],
      &__MODULE__.handle_finch/4,
      self()
    )

    client = EmbeddingProvider.client!()

    steps =
      Enum.map(plan.documents, &{:document, &1.id, &1.text}) ++
        Enum.map(plan.queries, &{:query, &1["id"], &1["text"]})

    {attempts, vectors, stopped} =
      Enum.reduce_while(steps, {[], %{}, nil}, fn step, {attempts, vectors, nil} ->
        case embed(client, step, attempts) do
          {{:ok, vector}, attempts} ->
            {:cont, {attempts, Map.put(vectors, elem(step, 1), vector), nil}}

          {{:error, reason}, attempts} ->
            {:halt, {attempts, vectors, "#{elem(step, 1)}: #{inspect(reason)}"}}
        end
      end)

    attempts = Enum.reverse(attempts)

    meta = %{
      issue: @issue,
      code: %{sha: sha, dirty: false},
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      runtime: plan.runtime,
      fixture_hashes: plan.fixture_hashes,
      embedding: "pgvector text of Tips.Content.Search.EmbeddingProvider's vector",
      plan: Map.drop(plan, [:runtime, :fixture_hashes, :documents, :queries]),
      stopped: stopped,
      requests: attempts,
      usage: usage(attempts)
    }

    write(output, meta, plan, vectors)
    IO.puts("#{length(attempts)} requests, #{map_size(vectors)} vectors, stopped: #{stopped}")
    if stopped == nil, do: 0, else: 1
  end

  # Sends one request, and once more after a deadline, within the request budget.
  defp embed(client, {kind, id, text} = step, attempts, retries \\ 1) do
    if length(attempts) >= @max_requests do
      {{:error, :request_budget}, attempts}
    else
      started_at = DateTime.utc_now() |> DateTime.to_iso8601()
      started = System.monotonic_time(:millisecond)

      result =
        if kind == :document,
          do: EmbeddingProvider.embed_document(client, text),
          else: EmbeddingProvider.embed_query(client, text)

      ms = System.monotonic_time(:millisecond) - started

      finch =
        receive do
          {:request, record} -> Map.delete(record, :input)
        after
          1_000 -> nil
        end

      attempt = %{
        kind: kind,
        id: id,
        started_at: started_at,
        ms: ms,
        result: if(match?({:ok, _vector}, result), do: "ok", else: inspect(elem(result, 1))),
        finch: finch
      }

      case result do
        {:error, :deadline} when retries > 0 -> embed(client, step, [attempt | attempts], 0)
        result -> {result, [attempt | attempts]}
      end
    end
  end

  defp usage(attempts) do
    records = attempts |> Enum.map(& &1.finch) |> Enum.reject(&is_nil/1)

    %{
      requests: length(attempts),
      unrecorded_requests: length(attempts) - length(records),
      answered_by: records |> Enum.map(& &1.provider) |> Enum.frequencies(),
      prompt_tokens:
        records |> Enum.map(& &1.prompt_tokens) |> Enum.filter(&is_integer/1) |> Enum.sum(),
      cost_usd: records |> Enum.map(& &1.cost_usd) |> Enum.filter(&is_number/1) |> Enum.sum()
    }
  end

  defp write(path, meta, plan, vectors) do
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
      for %{"id" => id} <- plan.queries,
          Map.has_key?(vectors, id),
          do: %{id: id, embedding: vectors[id]}

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

System.halt(SearchGateVectorsScript.main(System.argv()))
