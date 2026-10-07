defmodule Tips.SearchGate do
  @moduledoc """
  The integrated search gate of #60. The frozen protocol, rules and thresholds
  are in `test/fixtures/search_probe/gate-60.json`; `scripts/search_gate.exs`
  runs it.

  `load/1` reads the fixtures and refuses changed hashes. `run/2` seeds the
  corpus through the shared search-text writer, then runs the protocol steps
  with the application's own scan, search and provider code, and returns the
  report. It never retries. It stops at the first provider error, except a
  query embedding over its budget: the search falls back to keyword results,
  which the gate records and counts.

  Provider requests are observed outside the application: the script attaches
  `handle_finch_start/4` and `handle_finch/4` to Finch's request telemetry,
  and tests call `request_started/0` and `observe/1` from their stub. Each
  observation goes to the running gate. During the document scan a request
  starts only if every earlier one ended with a valid embedding, so the scan
  makes no request after a failure, including a request killed at its
  deadline, which never ends. A request that never ends is reported with
  outcome `"no response"`. Input text only matches a request to its document; it
  is never reported.
  """

  import Ecto.Query

  alias Tips.Accounts
  alias Tips.Content
  alias Tips.Content.{Review, Search, Tip}
  alias Tips.Content.Search.{EmbeddingProvider, ProviderCapacity}
  alias Tips.Content.Search.EmbeddingProvider.OpenRouter
  alias Tips.Repo
  alias Tips.Workers.EmbedSearch

  @dir "test/fixtures/search_probe"
  @files ~w(corpus.json queries.json gate-v2.json gate-60.json)
  @models ~w(claude gpt gemini)
  @environments ~w(chat ide cli)
  @base_url "https://openrouter.ai/api/v1"
  @max_document_bytes 30_000
  @max_body_codepoints 20_000
  @tokens_per_input 8
  @passes 3
  @deep_offset 180
  @saturated_requests 3
  @saturation_allowance_ms 250
  @deadline_fallback inspect({:embedding, :deadline})
  @query_phases [:passes, :vectors, :burst]
  @observer {__MODULE__, :observer}
  # Request counters of the current phase.
  @started 1
  @ended 2
  @ok 3

  ## Fixtures

  @doc "Reads the gate fixtures from `dir` and checks their frozen hashes."
  def load(dir \\ @dir) do
    gate = read_json(dir, "gate-60.json")
    hashes = Map.new(@files, &{&1, sha256(Path.join(dir, &1))})
    changed = for {name, hash} <- gate["fixture_hashes"], hashes[name] != hash, do: name

    if changed == [] do
      {:ok,
       %{
         gate: gate,
         corpus: read_json(dir, "corpus.json")["documents"],
         queries: read_json(dir, "queries.json")["queries"],
         hashes: hashes
       }}
    else
      {:error, {:fixture_hashes, changed}}
    end
  end

  @doc "Each corpus tip's model and environment, by its position among corpus tips."
  def setup(corpus) do
    corpus
    |> Enum.filter(&(&1["kind"] == "tip"))
    |> Enum.with_index()
    |> Map.new(fn {doc, i} ->
      {doc["id"],
       %{
         model: Enum.at(@models, rem(i, 3)),
         environment: Enum.at(@environments, rem(div(i, 3), 3))
       }}
    end)
  end

  ## Run

  @doc """
  Runs the protocol and returns `{status, report}` with status `:passed`,
  `:failed` (a gate rule failed) or `:stopped` (a stop rule ended the run).

  The run calls the provider only when opted in: with `real: true`, or with a
  `:preflight_plug` from a test. Otherwise it stops before seeding.

  Options:

    * `:real` - call OpenRouter. `scripts/search_gate.exs` sets it only for
      `--real` with `TIPS_REAL_PROVIDERS=1`;
    * `:preflight_plug` - a `Req` plug for the preflight requests, for tests;
    * `:require_empty` - refuse a database that already has tips. Default `true`.
  """
  def run(fixtures, opts \\ []) do
    handler = {__MODULE__, :search, self()}
    :telemetry.attach(handler, [:tips, :search, :request], &__MODULE__.handle_search/4, self())
    sampler = start_rss_sampler()

    state = %{
      fixtures: fixtures,
      opts: opts,
      setup: setup(fixtures.corpus),
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started: now_ms(),
      documents: %{},
      requests: [],
      phase: nil,
      counts: nil,
      report: %{}
    }

    steps = [
      &opt_in/1,
      &seed/1,
      &plan/1,
      &preflight/1,
      &documents/1,
      &passes/1,
      &vectors/1,
      &saturation/1,
      &burst/1
    ]

    result =
      Enum.reduce_while(steps, {:ok, state}, fn step, {:ok, state} ->
        case run_step(step, state) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:stop, reason, state} -> {:halt, {:stop, reason, state}}
        end
      end)

    :telemetry.detach(handler)
    :persistent_term.erase(@observer)
    report(result, stop_rss_sampler(sampler))
  end

  # A crash after provider requests must still produce the report.
  defp run_step(step, state) do
    step.(state)
  rescue
    exception -> {:stop, {:crash, Exception.message(exception)}, state}
  end

  ## Step 1: seed and plan

  defp opt_in(%{opts: opts} = state) do
    if opts[:real] == true or opts[:preflight_plug],
      do: {:ok, state},
      else: {:stop, :not_opted_in, state}
  end

  defp seed(%{fixtures: %{corpus: corpus}, opts: opts} = state) do
    if Keyword.get(opts, :require_empty, true) and Repo.exists?(Tip) do
      {:stop, :database_not_empty, state}
    else
      {:ok, ids} = Repo.transact(fn -> {:ok, seed_corpus(corpus)} end)
      corpus_ids = Map.new(ids, fn {id, row} -> {row, id} end)
      {:ok, Map.merge(state, %{ids: ids, corpus_ids: corpus_ids})}
    end
  end

  @doc """
  Persists the corpus as `corpus_setup` in `gate-60.json` describes and writes
  every search document. Returns each persisted corpus id with its row,
  `{:tip, id}` or `{:review, id}`. Call it inside a transaction.
  """
  def seed_corpus(corpus) do
    setup = setup(corpus)
    author = user!("gate-author")

    tips =
      for %{"kind" => "tip", "state" => state} = doc <- corpus,
          state in ~w(published hidden deleted),
          into: %{} do
        %{model: model, environment: environment} = setup[doc["id"]]
        {body, output} = split_body(doc["body"])

        tip =
          Repo.insert!(%Tip{
            user_id: author.id,
            submission_key: Ecto.UUID.generate(),
            title: doc["title"],
            body: body,
            output: output,
            tag_id: "other",
            model_id: model,
            environment_id: environment,
            created_at: DateTime.utc_now(:second)
          })

        :ok = Search.write_tip_text(tip.id)
        {doc["id"], tip}
      end

    reviews =
      for %{"kind" => "review"} = doc <- corpus, into: %{} do
        review =
          Repo.insert!(%Review{
            tip_id: tips[doc["parent_id"]].id,
            user_id: user!("gate-#{doc["id"]}").id,
            submission_key: Ecto.UUID.generate(),
            body: doc["body"],
            created_at: DateTime.utc_now(:second)
          })

        :ok = Search.write_review_text(review.id)
        {doc["id"], review}
      end

    for %{"id" => id, "state" => marker} <- corpus, marker in ~w(hidden deleted) do
      field = if marker == "hidden", do: :dead_at, else: :deleted_at
      tips[id] |> Ecto.Changeset.change(%{field => DateTime.utc_now(:second)}) |> Repo.update!()
    end

    Map.merge(
      Map.new(tips, fn {id, tip} -> {id, {:tip, tip.id}} end),
      Map.new(reviews, fn {id, review} -> {id, {:review, review.id}} end)
    )
  end

  @doc """
  Splits a tip body over the 20,000-codepoint limit at its last whitespace
  within the limit: `{body, output}`, `output` `nil` when the body fits.
  """
  def split_body(body) do
    if String.length(body) <= @max_body_codepoints do
      {body, nil}
    else
      head = String.slice(body, 0, @max_body_codepoints)
      [_whole, {at, length}] = Regex.run(~r/(\s)\S*\z/u, head, return: :index)
      rest = at + length
      {binary_part(body, 0, at), binary_part(body, rest, byte_size(body) - rest)}
    end
  end

  defp user!(handle) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        handle: String.slice("#{handle}-#{unique}", 0, 30),
        email: "#{handle}-#{unique}@example.com"
      })

    user
  end

  defp plan(%{fixtures: %{gate: gate, queries: queries}} = state) do
    documents = eligible_documents(state.corpus_ids)
    planned = gate["protocol"]["planned_requests"]

    reserved =
      gate["protocol"]["reserved_after_run"]["browser_journey_searches"] +
        gate["protocol"]["requests_before_this_run"]

    budget = gate["budget"]
    sizes = Map.new(documents, fn {id, text} -> {id, byte_size(text)} end)
    instruction = OpenRouter.runtime().query_instruction
    query_tokens = Enum.map(queries, &tokens(instruction <> &1["text"]))

    token_bound =
      Enum.sum(Enum.map(documents, fn {_id, text} -> tokens(text) end)) +
        Enum.sum(query_tokens) * (@passes + 1) +
        Enum.sum(Enum.take(query_tokens, planned["burst"]))

    plan = %{
      eligible_documents: map_size(documents),
      document_bytes: sizes,
      max_document_bytes: sizes |> Map.values() |> Enum.max(fn -> 0 end),
      requests: planned["total"],
      reserved_requests: reserved,
      token_bound: token_bound
    }

    state = %{put_report(state, :plan, plan) | documents: documents}

    cond do
      plan.eligible_documents != gate["corpus_setup"]["eligible_documents"] ->
        {:stop, :eligible_count, state}

      plan.max_document_bytes > @max_document_bytes ->
        {:stop, :document_too_large, state}

      planned["total"] + reserved > budget["max_requests"] ->
        {:stop, :request_budget, state}

      token_bound > budget["max_input_tokens"] ->
        {:stop, :token_budget, state}

      true ->
        {:ok, state}
    end
  end

  defp tokens(text), do: byte_size(text) + @tokens_per_input

  defp eligible_documents(corpus_ids) do
    tips =
      Repo.all(
        from s in "tip_search",
          join: t in Tip,
          on: t.id == s.tip_id and is_nil(t.deleted_at) and is_nil(t.dead_at),
          select: {s.tip_id, s.search_text}
      )

    reviews =
      Repo.all(
        from s in "review_search",
          join: r in Review,
          on: r.id == s.review_id and is_nil(r.deleted_at) and is_nil(r.dead_at),
          join: t in Tip,
          on: t.id == r.tip_id and is_nil(t.deleted_at) and is_nil(t.dead_at),
          select: {s.review_id, s.search_text}
      )

    Map.new(
      Enum.map(tips, fn {id, text} -> {corpus_ids[{:tip, id}], text} end) ++
        Enum.map(reviews, fn {id, text} -> {corpus_ids[{:review, id}], text} end)
    )
  end

  ## Step 2: preflight

  defp preflight(%{fixtures: %{gate: gate}} = state) do
    state = phase(state, :preflight)
    plug = if plug = state.opts[:preflight_plug], do: [plug: plug], else: []
    client = Req.new([base_url: @base_url, retry: false, redirect: false] ++ plug)
    {result, listed} = endpoint(client)
    result = with {:ok, endpoint} <- result, {:ok, key} <- key(client), do: {:ok, endpoint, key}
    state = state |> drain() |> put_report(:preflight, %{listed_endpoints: listed})

    case result do
      {:ok, endpoint, key} ->
        estimate = state.report.plan.token_bound * endpoint.prompt_price_usd_per_token

        state =
          update_in(
            state.report.preflight,
            &Map.merge(&1, %{
              endpoint: endpoint,
              key: key,
              estimated_max_cost_usd: estimate,
              host_before:
                "#234 and gate runs 1 to 4 used DeepInfra; #363 measured Nebius; this run's tag is #{endpoint.tag}"
            })
          )

        cond do
          estimate > gate["budget"]["max_cost_usd"] ->
            {:stop, :cost_budget, state}

          endpoint.context_tokens < tokens(String.duplicate("x", @max_document_bytes)) ->
            {:stop, :endpoint_context, state}

          is_number(key.limit_remaining_usd) and key.limit_remaining_usd < estimate ->
            {:stop, :key_limit, state}

          true ->
            {:ok, state}
        end

      {:error, reason} ->
        {:stop, {:preflight, reason}, state}
    end
  end

  # Returns the one listed endpoint of the configured host, tagged `<host>` or
  # `<host>/<variant>`, and every listed endpoint for the report. Routing by
  # provider cannot choose between two endpoints of one host, so two stop the run.
  defp endpoint(client) do
    %{model: model, host: host} = OpenRouter.runtime()

    case Req.get(client, url: "/models/#{model}/endpoints") do
      {:ok, %{status: 200, body: %{"data" => %{"endpoints" => endpoints}}}}
      when is_list(endpoints) ->
        listed = Enum.map(endpoints, &listing/1)

        case Enum.filter(listed, &host?(&1, host)) do
          [%{context_tokens: context, prompt_price_usd_per_token: price} = endpoint]
          when is_integer(context) and is_float(price) ->
            {{:ok, endpoint}, listed}

          [] ->
            {{:error, :endpoint_unlisted}, listed}

          [_incomplete] ->
            {{:error, :endpoint_incomplete}, listed}

          _several ->
            {{:error, :endpoints_ambiguous}, listed}
        end

      response ->
        {{:error, failure(response)}, []}
    end
  end

  defp listing(%{} = endpoint) do
    price =
      with %{"pricing" => %{"prompt" => price}} when is_binary(price) <- endpoint,
           {price, ""} <- Float.parse(price) do
        price
      else
        _missing -> nil
      end

    %{
      provider: endpoint["provider_name"],
      tag: endpoint["tag"],
      status: endpoint["status"],
      quantization: endpoint["quantization"],
      context_tokens: endpoint["context_length"],
      prompt_price_usd_per_token: price
    }
  end

  defp listing(other), do: %{unexpected: inspect(other)}

  defp host?(%{tag: tag}, host) when is_binary(tag),
    do: tag == host or String.starts_with?(tag, host <> "/")

  defp host?(_listing, _host), do: false

  # Records the key's limits, never its label or usage.
  defp key(client) do
    # The key the embedding requests will use.
    api_key =
      Application.get_env(:tips, OpenRouter, [])[:api_key] ||
        Tips.ProviderConfig.fetch!("OPENROUTER_API_KEY")

    auth = {:bearer, api_key}

    case Req.get(client, url: "/key", auth: auth) do
      {:ok, %{status: 200, body: %{"data" => %{} = data}}} ->
        {:ok,
         %{
           is_free_tier: data["is_free_tier"],
           limit_usd: data["limit"],
           limit_remaining_usd: data["limit_remaining"]
         }}

      response ->
        {:error, failure(response)}
    end
  end

  defp failure({:ok, %{status: status}}), do: {:http, status}
  defp failure({:error, _exception}), do: :transport

  ## Step 3: the document scan

  defp documents(state) do
    state = phase(state, :documents)
    callers = [self() | Process.get(:"$callers", [])]
    started = now_ms()

    # Unlinked, so a request killed by the observer ends the scan, not the gate.
    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        {:ok, summary} = EmbedSearch.perform(%Oban.Job{args: %{}})
        exit({:shutdown, {:scan, summary}})
      end)

    outcome =
      receive do
        {:DOWN, ^ref, :process, ^pid, {:shutdown, {:scan, summary}}} -> {:ok, summary}
        {:DOWN, ^ref, :process, ^pid, reason} -> {:error, reason}
      end

    wall_ms = now_ms() - started
    state = close_phase(state)
    requests = phase_requests(state, :documents)
    embedded = embedded_documents(state.corpus_ids)

    scan = %{
      wall_ms: wall_ms,
      summary: scan_summary(outcome),
      requests: length(requests),
      embedded: length(embedded),
      embedded_per_minute:
        if(wall_ms > 0, do: Float.round(length(embedded) * 60_000 / wall_ms, 1)),
      unmatched_inputs: Enum.count(requests, &is_nil(&1.document)),
      ineligible_embedded: embedded -- Map.keys(state.documents)
    }

    state = put_report(state, :scan, scan)

    case outcome do
      {:ok, %{embedded: 40, failed: failed, skipped: 0, stale: 0}} when map_size(failed) == 0 ->
        {:ok, state}

      {:ok, _summary} ->
        {:stop, :scan_incomplete, state}

      {:error, _reason} ->
        {:stop, :provider_error, state}
    end
  end

  defp embedded_documents(corpus_ids) do
    tips = Repo.all(from s in "tip_search", where: not is_nil(s.embedding), select: s.tip_id)

    reviews =
      Repo.all(from s in "review_search", where: not is_nil(s.embedding), select: s.review_id)

    Enum.map(tips, &corpus_ids[{:tip, &1}]) ++ Enum.map(reviews, &corpus_ids[{:review, &1}])
  end

  defp scan_summary({:ok, summary}),
    do: Map.update!(summary, :failed, &Map.new(&1, fn {k, v} -> {inspect(k), v} end))

  defp scan_summary({:error, reason}), do: %{exit: inspect(reason)}

  ## Step 4: three query passes

  defp passes(%{fixtures: %{queries: queries}} = state) do
    state = phase(state, :passes)
    runs = for pass <- 1..@passes, query <- queries, do: {pass, query}

    Enum.reduce_while(runs, {:ok, state}, fn {pass, query}, {:ok, state} ->
      {record, state} = pass_search(state, query, pass)
      state = add_report(state, :passes, record)

      if answered?(record),
        do: {:cont, {:ok, state}},
        else: {:halt, {:stop, :query_failed, state}}
    end)
  end

  # A hybrid result, or keyword results after the query embedding passed its budget.
  defp answered?(%{result: "hybrid"}), do: true
  defp answered?(%{result: "keyword", reason: @deadline_fallback}), do: true
  defp answered?(_record), do: false

  defp pass_search(state, query, pass) do
    before = length(state.requests)
    started = now_ms()
    result = Content.search_tips(nil, query["text"], [])
    total_ms = now_ms() - started
    state = drain(state)
    [event] = search_events(1)
    top = top(result, state)

    provider_ms =
      case Enum.take(state.requests, length(state.requests) - before) do
        [%{outcome: "ok"} = request] -> request.duration_ms
        _none_or_more -> nil
      end

    record =
      Map.merge(
        %{pass: pass, query: query["id"], total_ms: total_ms, provider_ms: provider_ms, top: top},
        event
      )

    {Map.merge(record, recall(query["relevant"], top, state.ids)), state}
  end

  defp top({:ok, %{entries: entries}}, state) do
    entries
    |> Enum.take(5)
    |> Enum.map(fn entry ->
      %{
        tip: state.corpus_ids[{:tip, entry.tip.id}],
        review: entry.matched_review_id && state.corpus_ids[{:review, entry.matched_review_id}],
        source: entry.excerpt && entry.excerpt.source
      }
    end)
  end

  defp top({:error, reason}, _state), do: %{error: inspect(reason)}

  @doc """
  Recall of `relevant` corpus ids in `top`, under the gate's relevance unit: a
  tip document is retrieved when its tip is listed, a review document when it
  is the listed tip's matched review.
  """
  def recall(relevant, top, ids) when is_list(top) do
    retrieved =
      Enum.filter(relevant, fn id ->
        case ids[id] do
          {:tip, _id} -> Enum.any?(top, &(&1.tip == id))
          {:review, _id} -> Enum.any?(top, &(&1.review == id))
        end
      end)

    %{retrieved: retrieved, hit: retrieved != [], recall: length(retrieved) / length(relevant)}
  end

  def recall(_relevant, %{error: _reason}, _ids), do: %{retrieved: [], hit: false, recall: 0.0}

  ## Step 5: query vectors, filters, keyword-only and the deepest offset

  defp vectors(%{fixtures: %{queries: queries}} = state) do
    state = phase(state, :vectors)
    client = EmbeddingProvider.client!()

    result =
      Enum.reduce_while(queries, {:ok, state}, fn query, {:ok, state} ->
        case EmbeddingProvider.embed_query(client, query["text"]) do
          {:ok, literal} ->
            {:cont,
             {:ok, add_report(state, :vectors, vector_checks(query, values(literal), state))}}

          # Over its budget, as in a search: recorded, and the query's checks are skipped.
          {:error, :deadline} ->
            {:cont, {:ok, add_report(state, :vectors, %{query: query["id"], deadline: true})}}

          {:error, reason} ->
            error = %{query: query["id"], reason: inspect(reason)}
            {:halt, {:stop, :provider_error, put_report(state, :vector_error, error)}}
        end
      end)

    case result do
      {:ok, state} -> {:ok, drain(state)}
      {:stop, reason, state} -> {:stop, reason, drain(state)}
    end
  end

  defp vector_checks(query, vector, state) do
    text = query["text"]
    relevant = query["relevant"]
    {hybrid, _ms} = timed(fn -> search(state, text, embedding: vector) end)
    {keyword, keyword_ms} = timed(fn -> search(state, text, []) end)

    {deep, deep_ms} =
      timed(fn -> Search.search(nil, text, embedding: vector, offset: @deep_offset) end)

    filtered =
      for {model, docs} <- Enum.group_by(relevant, &model_of(&1, state)) do
        {:ok, %{entries: entries}} =
          page = Search.search(nil, text, embedding: vector, model_id: model)

        top = top(page, state)
        tips = Enum.map(entries, &state.corpus_ids[{:tip, &1.tip.id}])

        %{
          model: model,
          relevant: docs,
          only_model: Enum.all?(tips, &(model_of(&1, state) == model)),
          filtered_recall: recall(docs, top, state.ids).recall,
          unfiltered_recall: recall(docs, hybrid, state.ids).recall
        }
      end

    %{
      query: query["id"],
      hybrid_top: hybrid,
      keyword_top: keyword,
      keyword_ms: keyword_ms,
      keyword_recall: recall(relevant, keyword, state.ids).recall,
      filtered: filtered,
      deep_offset: %{offset: @deep_offset, ms: deep_ms, entries: deep_entries(deep)}
    }
  end

  defp search(state, text, opts), do: top(Search.search(nil, text, opts), state)

  defp deep_entries({:ok, %{entries: entries}}), do: length(entries)
  defp deep_entries({:error, reason}), do: inspect(reason)

  defp model_of(id, %{fixtures: %{corpus: corpus}, setup: setup}) do
    case Enum.find(corpus, &(&1["id"] == id)) do
      %{"kind" => "review", "parent_id" => tip} -> setup[tip].model
      %{"kind" => "tip"} -> setup[id].model
    end
  end

  defp values(literal) do
    literal
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",")
    |> Enum.map(fn value ->
      {float, ""} = Float.parse(value)
      float
    end)
  end

  ## Step 6: saturated capacity

  defp saturation(%{fixtures: %{queries: queries}} = state) do
    state = phase(state, :saturation)
    size = Application.fetch_env!(:tips, ProviderCapacity)[:size]
    holders = for _slot <- 1..size, do: hold_slot()
    results = queries |> Enum.take(@saturated_requests) |> concurrent_searches()
    Enum.each(holders, &send(&1, :release))
    state = drain(state)

    record = %{
      held_slots: size,
      requests: length(phase_requests(state, :saturation)),
      limit_ms: Application.fetch_env!(:tips, Search)[:total] + @saturation_allowance_ms,
      results: results,
      outcomes: search_events(length(results))
    }

    {:ok, put_report(state, :saturation, record)}
  end

  defp hold_slot do
    owner = self()

    pid =
      spawn(fn ->
        ProviderCapacity.run(now_ms() + 60_000, fn ->
          send(owner, {:held, self()})

          receive do
            :release -> :ok
          after
            60_000 -> :ok
          end
        end)
      end)

    receive do
      {:held, _holder} -> pid
    after
      5_000 -> raise "could not hold a provider capacity slot"
    end
  end

  ## Step 7: a burst at capacity

  defp burst(%{fixtures: %{gate: gate, queries: queries}} = state) do
    state = phase(state, :burst)
    count = gate["protocol"]["planned_requests"]["burst"]
    {results, wall_ms} = timed(fn -> queries |> Enum.take(count) |> concurrent_searches() end)
    state = drain(state)

    record = %{
      wall_ms: wall_ms,
      requests: length(phase_requests(state, :burst)),
      results: results,
      outcomes: search_events(length(results))
    }

    {:ok, put_report(state, :burst, record)}
  end

  defp concurrent_searches(queries) do
    queries
    |> Enum.map(&Task.async(fn -> timed_search(&1) end))
    |> Task.await_many(30_000)
  end

  defp timed_search(query) do
    {result, ms} = timed(fn -> Content.search_tips(nil, query["text"], []) end)
    %{query: query["id"], total_ms: ms, page: match?({:ok, _page}, result)}
  end

  ## Observation

  @doc "Finch `[:finch, :request, :stop]` handler that observes OpenRouter requests."
  def handle_finch(
        _event,
        %{duration: duration},
        %{request: %{host: "openrouter.ai"} = request} = metadata,
        _config
      ) do
    {status, body} =
      case metadata.result do
        {:ok, {_req, {status, _headers, body, _trailers}}} -> {status, IO.iodata_to_binary(body)}
        {:ok, %{status: status, body: body}} -> {status, body}
        {:error, _exception} -> {nil, nil}
      end

    ms = System.convert_time_unit(duration, :native, :millisecond)
    observe(request_record(request.path, request_input(request.body), status, body, ms))
  end

  def handle_finch(_event, _measurements, _metadata, _config), do: :ok

  @doc "Finch `[:finch, :request, :start]` handler that counts OpenRouter requests."
  def handle_finch_start(_event, _measurements, %{request: %{host: "openrouter.ai"}}, _config),
    do: request_started()

  def handle_finch_start(_event, _measurements, _metadata, _config), do: :ok

  @doc """
  Counts a provider request as it starts. During the document scan it kills
  the calling process instead, before the request is sent, when an earlier
  request did not end with a valid embedding.
  """
  def request_started do
    case :persistent_term.get(@observer, nil) do
      nil ->
        :ok

      %{phase: phase, counts: counts} ->
        if phase == :documents and :counters.get(counts, @started) != :counters.get(counts, @ok),
          do: Process.exit(self(), :kill)

        :counters.add(counts, @started, 1)
    end
  end

  defp request_input(body) when is_binary(body) or is_list(body) do
    case JSON.decode(IO.iodata_to_binary(body)) do
      {:ok, %{"input" => [input]}} -> input
      _other -> nil
    end
  end

  defp request_input(_body), do: nil

  @doc """
  One provider request from its path, input text (matched, never reported),
  response status (`nil` for a transport error), body and duration.
  """
  def request_record(path, input, status, body, duration_ms) do
    response =
      with 200 <- status, {:ok, %{} = decoded} <- JSON.decode(body) do
        decoded
      else
        _not_a_response -> %{}
      end

    embedding =
      case response do
        %{"data" => [%{"embedding" => values} | _rest]} when is_list(values) -> values
        _other -> nil
      end

    usage =
      case response do
        %{"usage" => %{} = usage} -> usage
        _other -> %{}
      end

    path = path |> String.split("/") |> List.last()

    %{
      path: path,
      input: input,
      outcome: outcome(status, path, body, response),
      duration_ms: duration_ms,
      model: response["model"],
      provider: response["provider"],
      returned_length: embedding && length(embedding),
      prompt_tokens: usage["prompt_tokens"],
      cost_usd: usage["cost"]
    }
  end

  # An embedding the application rejects, including one served by another
  # upstream, is a runtime failure, so it stops the run.
  defp outcome(200, "embeddings", body, response) do
    case OpenRouter.decode(body) do
      {:ok, _vector} ->
        "ok"

      {:error, :contract} ->
        "contract: model #{inspect(response["model"])}, provider #{inspect(response["provider"])}"

      {:error, :malformed} ->
        "malformed"
    end
  end

  defp outcome(200, _path, _body, _response), do: "ok"
  defp outcome(nil, _path, _body, _response), do: "transport"
  defp outcome(status, _path, _body, _response), do: "http #{status}"

  @doc """
  Sends `record` to the running gate. During the document scan a failed
  request kills the calling process, so the scan stops before its next request.
  """
  def observe(record) do
    case :persistent_term.get(@observer, nil) do
      nil ->
        :ok

      %{pid: pid, phase: phase, counts: counts} ->
        send(pid, {__MODULE__, :request, phase, now_ms(), record})
        :counters.add(counts, @ended, 1)
        if record.outcome == "ok", do: :counters.add(counts, @ok, 1)
        if phase == :documents and record.outcome != "ok", do: Process.exit(self(), :kill)
        :ok
    end
  end

  @doc false
  def handle_search(_event, _measurements, metadata, owner),
    do: send(owner, {__MODULE__, :search, metadata})

  defp search_events(count) do
    for _n <- 1..count//1 do
      receive do
        {__MODULE__, :search, %{result: result, reason: reason}} ->
          %{result: to_string(result), reason: reason && inspect(reason)}
      after
        1_000 -> %{result: "missing", reason: nil}
      end
    end
  end

  defp phase(state, phase) do
    state = close_phase(state)
    counts = :counters.new(3, [:atomics])
    :persistent_term.put(@observer, %{pid: self(), phase: phase, counts: counts})
    %{state | phase: phase, counts: counts}
  end

  # Reports each request of the closing phase that started but never ended.
  defp close_phase(%{counts: nil} = state), do: state

  defp close_phase(%{counts: counts} = state) do
    state = drain(state)
    missing = :counters.get(counts, @started) - :counters.get(counts, @ended)

    request = %{
      path: "embeddings",
      outcome: "no response",
      duration_ms: nil,
      model: nil,
      provider: nil,
      returned_length: nil,
      prompt_tokens: nil,
      cost_usd: nil,
      phase: state.phase,
      at_ms: now_ms() - state.started,
      document: nil
    }

    %{state | requests: List.duplicate(request, missing) ++ state.requests, counts: nil}
  end

  defp drain(state) do
    receive do
      {__MODULE__, :request, phase, at, record} ->
        document =
          record.input &&
            Enum.find_value(state.documents, fn {id, text} -> text == record.input && id end)

        request =
          record
          |> Map.delete(:input)
          |> Map.merge(%{phase: phase, at_ms: at - state.started, document: document})

        drain(%{state | requests: [request | state.requests]})
    after
      0 -> state
    end
  end

  defp phase_requests(state, phase), do: Enum.filter(state.requests, &(&1.phase == phase))

  ## Memory

  defp start_rss_sampler do
    spawn_link(fn -> sample_rss(rss_kib(), rss_kib()) end)
  end

  defp sample_rss(baseline, peak) do
    receive do
      {:stop, from} -> send(from, {:rss, baseline, peak})
    after
      100 -> sample_rss(baseline, max_rss(peak, rss_kib()))
    end
  end

  defp stop_rss_sampler(pid) do
    send(pid, {:stop, self()})

    receive do
      {:rss, baseline, peak} ->
        %{
          method: "OS RSS of this BEAM, sampled every 100 ms from the start of the run",
          baseline_rss_kib: baseline,
          peak_rss_kib: peak,
          incremental_mib: if(peak && baseline, do: (peak - baseline) / 1024)
        }
    end
  end

  # A missed sample leaves the peak unknown, so the memory rule fails.
  defp max_rss(peak, rss) when is_integer(peak) and is_integer(rss), do: max(peak, rss)
  defp max_rss(_peak, _rss), do: nil

  # `nil` when `ps` is missing or refused.
  defp rss_kib do
    with {out, 0} <- System.cmd("ps", ["-o", "rss=", "-p", System.pid()], stderr_to_stdout: true),
         {kib, ""} <- out |> String.trim() |> Integer.parse() do
      kib
    else
      _failed -> nil
    end
  rescue
    ErlangError -> nil
  end

  ## Report

  defp report(result, memory) do
    {stopped, state} =
      case result do
        {:ok, state} -> {nil, state}
        {:stop, reason, state} -> {reason, state}
      end

    state = close_phase(state)
    requests = Enum.reverse(state.requests)

    report =
      state.report
      |> Map.update(:passes, [], &Enum.reverse/1)
      |> Map.update(:vectors, [], &Enum.reverse/1)

    gates = if stopped, do: [], else: gates(state.fixtures.gate, report, requests, memory)

    status =
      cond do
        stopped -> :stopped
        Enum.all?(gates, & &1.passed) -> :passed
        true -> :failed
      end

    report =
      Map.merge(report, %{
        status: status,
        stopped: stopped && inspect(stopped),
        gate_version: state.fixtures.gate["version"],
        fixtures: state.fixtures.hashes,
        setup: state.setup,
        started_at: state.started_at,
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        requests: requests,
        usage: usage(requests),
        memory: memory,
        latency: latency(report.passes),
        gates: gates
      })

    {status, report}
  end

  defp usage(requests) do
    %{
      requests: length(requests),
      failed_requests: Enum.count(requests, &(&1.outcome != "ok")),
      prompt_tokens:
        requests |> Enum.map(& &1.prompt_tokens) |> Enum.filter(&is_integer/1) |> Enum.sum(),
      cost_usd: requests |> Enum.map(& &1.cost_usd) |> Enum.filter(&is_number/1) |> Enum.sum(),
      cost_source: "provider-reported usage.cost"
    }
  end

  defp latency(passes) do
    totals = Enum.map(passes, & &1.total_ms)
    providers = passes |> Enum.map(& &1.provider_ms) |> Enum.reject(&is_nil/1)

    %{
      cold_request: List.first(passes),
      search_tips_ms: %{p95: p95(totals), max: Enum.max(totals, fn -> nil end)},
      provider_ms: %{p95: p95(providers), max: Enum.max(providers, fn -> nil end)},
      by_pass:
        for pass <- 1..@passes do
          ms = for %{pass: ^pass, total_ms: ms} <- passes, do: ms
          %{pass: pass, search_tips_ms: ms, p95: p95(ms)}
        end
    }
  end

  @doc "Nearest-rank 95th percentile; `nil` for no values."
  def p95([]), do: nil

  def p95(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, ceil(0.95 * length(sorted)) - 1)
  end

  defp gates(gate, report, requests, memory) do
    t = gate["gate"]
    passes = report.passes
    documents = Enum.filter(requests, &(&1.phase == :documents))
    {query_requests, other_requests} = Enum.split_with(requests, &(&1.phase in @query_phases))
    pass_requests = Enum.filter(query_requests, &(&1.phase == :passes and &1.outcome == "ok"))
    %{saturation: saturation, burst: burst} = report
    totals = Enum.map(passes, & &1.total_ms)
    provider_ms = Enum.map(pass_requests, & &1.duration_ms)
    vectors = Enum.reject(report.vectors, &Map.get(&1, :deadline))

    [
      check(
        "provider_requests_succeed",
        Enum.count(other_requests, &(&1.outcome != "ok")),
        "0 failed outside query embeddings",
        &(&1 == 0)
      ),
      check(
        "query_deadlines_recorded",
        %{
          failed_requests: Enum.count(query_requests, &(&1.outcome != "ok")),
          deadlines: deadlines(report)
        },
        "each failed query embedding is one recorded #{@deadline_fallback}",
        &(&1.failed_requests == &1.deadlines)
      ),
      check(
        "single_identity",
        identities(requests),
        "only #{inspect(identity())}: the configured model, upstream and dimensions",
        &(&1 == [identity()])
      ),
      check(
        "hybrid_per_pass",
        for(
          pass <- 1..@passes,
          do: Enum.count(passes, &(&1.pass == pass and &1.result == "hybrid"))
        ),
        ">= #{t["min_hybrid_queries_per_pass"]} of 10 hybrid in every pass",
        &(length(&1) == @passes and
            Enum.all?(&1, fn n -> n >= t["min_hybrid_queries_per_pass"] end))
      ),
      check(
        "long_input_sent_whole",
        Enum.count(t["long_input_cohort"], fn id -> Enum.any?(documents, &(&1.document == id)) end),
        "each cohort document's input equals its whole stored search_text",
        &(&1 == length(t["long_input_cohort"]))
      ),
      check(
        "search_tips_p95_ms",
        p95(totals),
        "<= #{t["query_p95_ms"]}",
        &(&1 <= t["query_p95_ms"])
      ),
      check(
        "search_tips_max_ms",
        Enum.max(totals ++ Enum.map(burst.results, & &1.total_ms)),
        "<= #{t["search_total_ms"]} for every pass and burst search",
        &(&1 <= t["search_total_ms"])
      ),
      check(
        "provider_query_p95_ms",
        p95(provider_ms),
        "<= #{t["query_p95_ms"]} over answered pass embeddings",
        &(&1 <= t["query_p95_ms"])
      ),
      check(
        "provider_query_max_ms",
        Enum.max(provider_ms, fn -> nil end),
        "<= #{t["query_deadline_ms"]} over answered pass embeddings",
        &(&1 <= t["query_deadline_ms"])
      ),
      check(
        "document_max_ms",
        documents |> Enum.map(& &1.duration_ms) |> Enum.max(fn -> nil end),
        "<= #{t["document_deadline_ms"]}",
        &(&1 <= t["document_deadline_ms"])
      ),
      check(
        "incremental_rss_mib",
        memory.incremental_mib,
        "<= #{t["max_incremental_rss_mib"]}",
        &(&1 <= t["max_incremental_rss_mib"])
      ),
      check(
        "filters_exact",
        Enum.count(vectors, fn v -> Enum.all?(v.filtered, & &1.only_model) end),
        "every filtered result has the filtered model, for each query with a vector",
        &(&1 == length(vectors))
      ),
      check(
        "deep_offset_empty",
        Enum.count(vectors, &(&1.deep_offset.entries == 0)),
        "offset #{@deep_offset} returns an empty page for this corpus, for each query with a vector",
        &(&1 == length(vectors))
      ),
      check(
        "saturation_within_budget",
        %{
          pages_in_time:
            Enum.count(saturation.results, &(&1.page and &1.total_ms <= saturation.limit_ms)),
          busy_fallbacks:
            Enum.count(saturation.outcomes, &(&1.reason == inspect({:embedding, :busy}))),
          requests: saturation.requests
        },
        "#{@saturated_requests} keyword pages after :busy within #{saturation.limit_ms} ms, no request",
        &(&1 == %{
            pages_in_time: @saturated_requests,
            busy_fallbacks: @saturated_requests,
            requests: 0
          })
      ),
      check(
        "burst_pages",
        Enum.count(burst.results, & &1.page),
        "every burst request returns a page",
        &(&1 == length(burst.results))
      )
    ]
  end

  # Query embeddings over their budget, as the searches and the vector step recorded them.
  defp deadlines(%{passes: passes, vectors: vectors, burst: burst}) do
    Enum.count(passes, &(&1.reason == @deadline_fallback)) +
      Enum.count(vectors, &Map.get(&1, :deadline)) +
      Enum.count(burst.outcomes, &(&1.reason == @deadline_fallback))
  end

  defp identities(requests) do
    requests
    |> Enum.filter(&(&1.path == "embeddings" and &1.outcome == "ok"))
    |> Enum.map(&[downcase(&1.model), downcase(&1.provider), &1.returned_length])
    |> Enum.uniq()
  end

  defp identity do
    %{model: model, upstream: upstream, dimensions: dimensions} = OpenRouter.runtime()
    [downcase(model), downcase(upstream), dimensions]
  end

  defp downcase(name) when is_binary(name), do: String.downcase(name)
  defp downcase(name), do: name

  defp check(name, value, threshold, passes?),
    do: %{
      name: name,
      value: value,
      threshold: threshold,
      passed: value != nil and passes?.(value)
    }

  ## Helpers

  defp put_report(state, key, value), do: %{state | report: Map.put(state.report, key, value)}

  defp add_report(state, key, value),
    do: %{state | report: Map.update(state.report, key, [value], &[value | &1])}

  defp timed(fun) do
    started = now_ms()
    result = fun.()
    {result, now_ms() - started}
  end

  defp read_json(dir, name), do: dir |> Path.join(name) |> File.read!() |> JSON.decode!()

  defp sha256(path), do: :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
