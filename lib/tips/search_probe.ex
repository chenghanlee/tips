defmodule Tips.SearchProbe do
  @moduledoc """
  Ten-query relevance gate for the hosted embedding candidate (issue #54).

  The corpus, queries, judgments and numeric gate live in `test/fixtures/search_probe/`
  and are frozen before any model comparison. `scripts/search_probe.exs` is the entry
  point:

      mix run scripts/search_probe.exs --validate
      TIPS_REAL_PROVIDERS=1 mix run scripts/search_probe.exs --real --output tmp/search-probe-54.json

  `--validate` (the default) checks fixtures and the offline request/token bound without
  HTTP. `--real` needs real provider mode as well; it embeds eligible documents and the
  instructed queries through OpenRouter with retries disabled and concurrency 1, then
  writes an allowlisted JSON report. The exit status is 0 only when every gate passes.

  This is an isolated probe, not the application's search implementation.
  """

  @fixtures_dir Path.expand("../../test/fixtures/search_probe", __DIR__)
  @files %{"corpus" => "corpus.json", "queries" => "queries.json", "gate" => "gate.json"}
  @categories ~w(scoped_change setup_environment long_output punctuation_error)
  # Byte-level BPE emits at most one token per byte; this margin covers special tokens.
  @tokens_per_input_margin 8
  # Endpoint listing and key check before any embedding request.
  @preflight_requests 2

  def fixtures_dir, do: @fixtures_dir

  ## Command line

  @doc "Runs the command line and returns its exit status."
  def main(argv, opts \\ []) do
    case OptionParser.parse(argv, strict: [validate: :boolean, real: :boolean, output: :string]) do
      {parsed, [], []} -> command(parsed, opts)
      _invalid -> usage()
    end
  end

  defp command(parsed, opts) do
    case {parsed[:real], parsed[:validate], parsed[:output]} do
      {true, nil, output} when is_binary(output) -> live_if_real(output, opts)
      {nil, _validate, nil} -> validate_only(opts)
      _other -> usage()
    end
  end

  defp live_if_real(output, opts) do
    case Keyword.get_lazy(opts, :mode, &Tips.ProviderConfig.mode/0) do
      :real -> live(output, opts)
      _stub -> refuse_live()
    end
  end

  defp usage do
    IO.puts("""
    usage: mix run scripts/search_probe.exs [--validate]
           TIPS_REAL_PROVIDERS=1 mix run scripts/search_probe.exs --real --output PATH\
    """)

    2
  end

  defp refuse_live do
    IO.puts("refusing live probe: set TIPS_REAL_PROVIDERS=1 (or use MIX_ENV=dev) with --real")
    2
  end

  defp validate_only(opts) do
    with {:ok, fixtures} <- fixtures(opts),
         {:ok, plan} <- plan(fixtures) do
      IO.puts("fixtures valid: #{fixtures.gate["version"]}")
      Enum.each(fixtures.hashes, fn {name, hash} -> IO.puts("  #{name} sha256 #{hash}") end)

      IO.puts(
        "  eligible documents #{plan.documents}, long #{plan.long_documents}, " <>
          "planned requests #{plan.requests}, input token bound #{plan.token_bound}"
      )

      0
    else
      {:error, errors} ->
        Enum.each(List.wrap(errors), &IO.puts("invalid: #{&1}"))
        1
    end
  end

  defp live(output, opts) do
    report =
      case fixtures(opts) do
        {:ok, fixtures} -> run(fixtures, opts)
        {:error, errors} -> %{status: "failed", blocker: nil, errors: errors}
      end

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, Jason.encode_to_iodata!(report, pretty: true))
    IO.puts("search probe #{report.status}: #{output}")

    Enum.each(Map.get(report, :gates, []), fn gate ->
      IO.puts("  #{if gate.passed, do: "pass", else: "FAIL"} #{gate.name} #{inspect(gate.value)}")
    end)

    if report.status == "passed", do: 0, else: 1
  end

  defp fixtures(opts) do
    case opts[:fixtures] do
      nil -> load(opts[:fixtures_dir] || @fixtures_dir)
      fixtures -> {:ok, fixtures}
    end
  end

  ## Fixtures

  @doc "Loads and validates the frozen fixtures, with a SHA-256 hash of each file."
  def load(dir) do
    raw = Map.new(@files, fn {name, file} -> {name, File.read!(Path.join(dir, file))} end)

    fixtures = %{
      corpus: Jason.decode!(raw["corpus"])["documents"],
      queries: Jason.decode!(raw["queries"])["queries"],
      gate: Jason.decode!(raw["gate"]),
      hashes: Map.new(raw, fn {name, bytes} -> {name, sha256(bytes)} end)
    }

    with :ok <- validate(fixtures), do: {:ok, fixtures}
  end

  @doc "Checks fixture shape and judgments; returns every problem found."
  def validate(%{corpus: corpus, queries: queries, gate: gate}) do
    eligible = corpus |> eligible() |> MapSet.new(& &1["id"])
    ids = Enum.map(corpus, & &1["id"])
    tips = for %{"kind" => "tip", "id" => id} <- corpus, into: MapSet.new(), do: id

    errors =
      [
        {length(queries) != 10, "expected exactly ten queries, got #{length(queries)}"},
        {MapSet.size(eligible) not in 30..50,
         "expected 30-50 eligible documents, got #{MapSet.size(eligible)}"},
        {length(ids) != length(Enum.uniq(ids)), "document ids are not unique"},
        {queries |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() != length(queries),
         "query ids are not unique"},
        {gate["dimensions"] != 1024, "gate dimensions must be 1024"}
      ] ++
        Enum.flat_map(corpus, &document_errors(&1, tips)) ++
        Enum.flat_map(queries, &query_errors(&1, eligible, gate))

    case for({true, message} <- errors, do: message) do
      [] -> :ok
      messages -> {:error, messages}
    end
  end

  defp document_errors(doc, tips) do
    id = doc["id"]

    [
      {doc["kind"] not in ["tip", "review"], "#{id}: unknown kind"},
      {doc["state"] not in ~w(published hidden deleted private draft), "#{id}: unknown state"},
      {doc["kind"] == "review" and doc["parent_id"] not in tips,
       "#{id}: review needs a tip parent"},
      {doc["kind"] == "tip" and not is_binary(doc["title"]), "#{id}: tip needs a title"},
      {not String.valid?(doc["body"] || <<0xFF>>) or String.trim(doc["body"]) == "",
       "#{id}: body must be non-blank UTF-8"}
    ]
  end

  defp query_errors(query, eligible, gate) do
    id = query["id"]
    relevant = query["relevant"] || []

    [
      {query["category"] not in @categories, "#{id}: unknown category"},
      {relevant == [], "#{id}: needs relevant documents"},
      {not is_binary(query["rationale"]) or String.trim(query["rationale"]) == "",
       "#{id}: needs a judgment rationale"},
      {match?({:error, _}, prepare_query(query["text"] || "", gate)), "#{id}: invalid query text"}
    ] ++
      for doc_id <- relevant,
          doc_id not in eligible,
          do: {true, "#{id}: relevant #{doc_id} is not an eligible document"}
  end

  @doc """
  Returns documents that may reach the provider: published tips, and published reviews
  whose parent tip is published. Hidden, deleted, private and draft text never leaves.
  """
  def eligible(corpus) do
    live_tips =
      for %{"kind" => "tip", "state" => "published", "id" => id} <- corpus,
          into: MapSet.new(),
          do: id

    Enum.filter(corpus, fn
      %{"kind" => "tip", "state" => "published"} -> true
      %{"kind" => "review", "state" => "published", "parent_id" => parent} -> parent in live_tips
      _ineligible -> false
    end)
  end

  ## Preparation

  @doc "Plain document text: a tip's title, a blank line and its body; a review's body."
  def document_text(%{"kind" => "tip", "title" => title, "body" => body}),
    do: title <> "\n\n" <> body

  def document_text(%{"kind" => "review", "body" => body}), do: body

  @doc "Prepares a document for embedding under the gate's byte cap."
  def prepare_document(doc, gate) do
    %{"document_max_bytes" => max, "truncation_separator" => separator} = gate["preparation"]
    full = document_text(doc)
    text = bound(full, max, separator)
    %{id: doc["id"], text: text, full_bytes: byte_size(full), truncated: text != full}
  end

  @doc "Prefixes a reader query with the model card's retrieval instruction."
  def prepare_query(text, gate) do
    %{"query_instruction" => instruction, "query_max_bytes" => max} = gate["preparation"]

    cond do
      not String.valid?(text) or String.trim(text) == "" -> {:error, :blank_query}
      byte_size(text) > max -> {:error, :query_too_long}
      true -> {:ok, instruction <> text}
    end
  end

  @doc """
  Bounds valid UTF-8 `text` to `max` bytes. Longer text keeps equal head and tail byte
  budgets, each cut back to a character boundary, joined by `separator`.
  """
  def bound(text, max, _separator) when byte_size(text) <= max, do: text

  def bound(text, max, separator) do
    budget = max - byte_size(separator)
    head = head_bytes(text, div(budget, 2))
    tail = tail_bytes(text, budget - div(budget, 2))
    head <> separator <> tail
  end

  defp head_bytes(text, n) do
    n = back_to_boundary(text, n)
    binary_part(text, 0, n)
  end

  defp back_to_boundary(text, n) when n > 0 and n < byte_size(text) do
    if continuation?(:binary.at(text, n)), do: back_to_boundary(text, n - 1), else: n
  end

  defp back_to_boundary(_text, n), do: n

  defp tail_bytes(text, n) do
    start = forward_to_boundary(text, byte_size(text) - n)
    binary_part(text, start, byte_size(text) - start)
  end

  defp forward_to_boundary(text, start) when start < byte_size(text) do
    if continuation?(:binary.at(text, start)),
      do: forward_to_boundary(text, start + 1),
      else: start
  end

  defp forward_to_boundary(_text, start), do: start

  defp continuation?(byte), do: Bitwise.band(byte, 0xC0) == 0x80

  ## Scoring

  @doc "Ranks unit document vectors by cosine similarity, ties broken by id."
  def rank(query, documents) do
    documents
    |> Enum.map(fn {id, vector} -> {id, dot(query, vector)} end)
    |> Enum.sort_by(fn {id, score} -> {-score, id} end)
  end

  @doc "Fraction of `relevant` ids within the first `k` ranked ids."
  def recall(ranked_ids, relevant, k) do
    top = ranked_ids |> Enum.take(k) |> MapSet.new()
    Enum.count(relevant, &(&1 in top)) / length(relevant)
  end

  @doc "Nearest-rank 95th percentile."
  def p95(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, ceil(0.95 * length(sorted)) - 1)
  end

  defp dot(a, b), do: a |> Enum.zip_with(b, &(&1 * &2)) |> Enum.sum()

  ## Provider

  @doc """
  Embeds `inputs` in one request. Returns unit vectors of the gate's dimensions.

  Every response must name the requested model and the pinned upstream, compared without
  case (OpenRouter reports `Qwen/Qwen3-Embedding-8B` from `DeepInfra` for
  `qwen/qwen3-embedding-8b` pinned to `deepinfra`). A 4096-value response is cut to its
  first 1024 values and renormalized (Matryoshka truncation). Once `expected_length` is
  set, any other length is an error. Errors are atoms or tuples of atoms and status codes;
  bodies and headers never leave this function.
  """
  def embed(inputs, provider) do
    body =
      %{model: provider.model, input: inputs}
      |> put_if(provider.send_dimensions, :dimensions, provider.dimensions)
      |> put_if(map_size(provider.routing) > 0, :provider, provider.routing)

    with {:ok, response} <-
           request(provider, method: :post, url: "/embeddings", json: body, auth: true),
         {:ok, data} <- response_data(response, length(inputs)),
         :ok <- identity(response, provider),
         {:ok, vectors, length} <- vectors(data, provider) do
      {:ok,
       %{
         vectors: vectors,
         returned_length: length,
         model: response["model"],
         provider: response["provider"],
         prompt_tokens: get_in(response, ["usage", "prompt_tokens"]),
         cost_usd: get_in(response, ["usage", "cost"])
       }}
    end
  end

  defp identity(%{"model" => model, "provider" => upstream}, provider)
       when is_binary(model) and is_binary(upstream) do
    cond do
      String.downcase(model) != String.downcase(provider.model) ->
        {:error, :model_mismatch}

      String.downcase(upstream) != String.downcase(provider.upstream) ->
        {:error, :upstream_mismatch}

      true ->
        :ok
    end
  end

  defp identity(_response, _provider), do: {:error, :missing_identity}

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  # One monotonic deadline covers pool checkout, connect, send, receive and JSON decode:
  # Finch's own timeouts each cover one phase. The receive and connect limits match the
  # deadline so Req's shorter defaults (15 s receive) never cut a 30 s document request;
  # Finch's default pool wait can only end a request earlier. On expiry the request
  # process is killed, so no late response is used; a request the provider already
  # accepted cannot be recalled.
  defp request(provider, opts) do
    {auth?, opts} = Keyword.pop(opts, :auth, false)
    deadline = provider.timeout_ms

    opts =
      [
        base_url: provider.base_url,
        retry: false,
        receive_timeout: deadline,
        connect_options: [timeout: deadline]
      ]
      |> Keyword.merge(if auth?, do: [auth: {:bearer, provider.api_key}], else: [])
      |> Keyword.merge(opts)
      |> Keyword.merge(provider.req_options)

    task = Task.async(fn -> Req.request(opts) end)

    case Task.yield(task, deadline) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> response(result)
      nil -> {:error, :timeout}
    end
  end

  defp response(result) do
    case result do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: 200}} -> {:error, :malformed_response}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, :timeout}
      {:error, %Req.TransportError{}} -> {:error, :transport}
      {:error, _exception} -> {:error, :request_failed}
    end
  end

  defp response_data(%{"data" => data}, count) when is_list(data) do
    indices = Enum.map(data, &(is_map(&1) && &1["index"]))

    if Enum.sort(indices) == Enum.to_list(0..(count - 1)//1),
      do: {:ok, Enum.sort_by(data, & &1["index"])},
      else: {:error, :bad_indices}
  end

  defp response_data(_response, _count), do: {:error, :malformed_response}

  defp vectors(data, provider) do
    Enum.reduce_while(data, {:ok, [], nil}, fn item, {:ok, acc, _length} ->
      case vector(item["embedding"], provider) do
        {:ok, vector} -> {:cont, {:ok, [vector | acc], length(item["embedding"])}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc, length} -> {:ok, Enum.reverse(acc), length}
      error -> error
    end
  end

  defp vector(values, _provider) when not is_list(values), do: {:error, :malformed_response}

  defp vector(values, %{expected_length: expected}) when expected not in [nil, length(values)],
    do: {:error, {:vector_length, length(values)}}

  defp vector(values, %{dimensions: dims}) when length(values) in [dims, 4096] do
    values = Enum.take(values, dims)
    norm = values |> Enum.map(&square/1) |> Enum.sum() |> :math.sqrt()

    cond do
      not Enum.all?(values, &is_number/1) -> {:error, :non_numeric_vector}
      norm == 0 -> {:error, :zero_vector}
      true -> {:ok, Enum.map(values, &(&1 / norm))}
    end
  end

  defp vector(values, _provider), do: {:error, {:vector_length, length(values)}}

  defp square(value) when is_number(value), do: value * value
  defp square(_value), do: 0

  ## Live run

  @doc "Offline request and input-token bound for one live run."
  def plan(%{corpus: corpus, queries: queries, gate: gate}) do
    docs = corpus |> eligible() |> Enum.map(&prepare_document(&1, gate))
    long = Enum.filter(docs, & &1.truncated)
    passes = gate["gate"]["query_passes"]

    query_bytes =
      Enum.sum_by(queries, fn query ->
        {:ok, text} = prepare_query(query["text"], gate)
        byte_size(text)
      end)

    inputs = length(docs) + length(long) + passes * length(queries) + 1
    # The first document may be sent twice when the dimensions parameter is rejected.
    bytes =
      Enum.sum_by(docs, &byte_size(&1.text)) + byte_size(hd(docs).text) +
        Enum.sum_by(long, & &1.full_bytes) + passes * query_bytes

    plan = %{
      documents: length(docs),
      long_documents: length(long),
      requests: @preflight_requests + inputs,
      token_bound: bytes + inputs * @tokens_per_input_margin,
      max_full_document_bytes: docs |> Enum.map(& &1.full_bytes) |> Enum.max()
    }

    budget = gate["budget"]

    cond do
      plan.requests > budget["max_requests"] -> {:error, "planned requests exceed the budget"}
      plan.token_bound > budget["max_input_tokens"] -> {:error, "token bound exceeds the budget"}
      true -> {:ok, plan}
    end
  end

  @doc "Runs the live probe and returns the report. Never raises on provider failures."
  def run(fixtures, opts \\ []) do
    %{gate: gate} = fixtures
    baseline = rss_kib()

    state = %{
      fixtures: fixtures,
      requests: [],
      rss_peak: baseline,
      docs: %{},
      full: %{},
      queries: %{},
      query_ms: [],
      dimensions_mode: nil,
      preflight: %{}
    }

    steps = [
      &check_plan/1,
      &check_endpoint/1,
      &check_key/1,
      &embed_documents/1,
      &embed_full_documents/1,
      &embed_queries/1
    ]

    result =
      case provider(gate, opts) do
        {:ok, provider} -> reduce_ok(steps, Map.put(state, :provider, provider), & &1.(&2))
        {:error, reason} -> {:error, reason, state}
      end

    report(result, baseline)
  end

  defp provider(gate, opts) do
    key = Keyword.get_lazy(opts, :api_key, &fetch_api_key/0)

    if is_binary(key) and String.trim(key) != "" do
      provider = gate["provider"]

      {:ok,
       %{
         api_key: key,
         base_url: provider["base_url"],
         model: gate["model"]["id"],
         routing: provider["routing"],
         upstream: hd(provider["routing"]["only"]),
         dimensions: gate["dimensions"],
         send_dimensions: true,
         expected_length: nil,
         timeout_ms: gate["gate"]["document_deadline_ms"],
         req_options: Keyword.get(opts, :req_options, [])
       }}
    else
      {:error, :missing_credentials}
    end
  end

  defp fetch_api_key do
    Tips.ProviderConfig.fetch!("OPENROUTER_API_KEY")
  rescue
    RuntimeError -> nil
  end

  defp check_plan(state) do
    case plan(state.fixtures) do
      {:ok, plan} -> {:ok, put_in(state.preflight[:plan], plan)}
      {:error, message} -> {:error, {:budget, message}, state}
    end
  end

  # Current price and context for the pinned upstream; no bound, no run.
  defp check_endpoint(state) do
    %{gate: gate} = state.fixtures
    [pinned] = gate["provider"]["routing"]["only"]
    url = "/models/#{gate["model"]["id"]}/endpoints"

    {result, state} =
      timed(state, %{phase: "endpoints"}, fn ->
        request(state.provider, method: :get, url: url)
      end)

    with {:ok, body} <- result,
         {:ok, endpoint} <- pinned_endpoint(body, pinned),
         {:ok, preflight} <- price_bound(endpoint, state.preflight.plan, gate) do
      {:ok, %{state | preflight: Map.merge(state.preflight, preflight)}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp pinned_endpoint(%{"data" => %{"endpoints" => endpoints}}, pinned)
       when is_list(endpoints) do
    case Enum.find(endpoints, &(&1["tag"] == pinned)) do
      nil -> {:error, :pinned_provider_unlisted}
      endpoint -> {:ok, endpoint}
    end
  end

  defp pinned_endpoint(_body, _pinned), do: {:error, :malformed_response}

  defp price_bound(endpoint, plan, gate) do
    with %{"context_length" => context, "pricing" => %{"prompt" => price}} <- endpoint,
         true <- is_integer(context),
         {price, ""} <- Float.parse(price) do
      preflight = %{
        endpoint: %{
          provider: endpoint["provider_name"],
          tag: endpoint["tag"],
          status: endpoint["status"],
          context_tokens: context,
          prompt_price_usd_per_token: price
        },
        estimated_max_cost_usd: plan.token_bound * price
      }

      instruction = byte_size(gate["preparation"]["query_instruction"])

      cond do
        preflight.estimated_max_cost_usd > gate["budget"]["max_cost_usd"] ->
          {:error, {:budget, "estimated cost bound exceeds the budget"}}

        plan.max_full_document_bytes + @tokens_per_input_margin > context ->
          {:error, {:budget, "full reference input may exceed the context"}}

        instruction + gate["preparation"]["query_max_bytes"] > context ->
          {:error, {:budget, "query instruction and cap exceed the context"}}

        true ->
          {:ok, preflight}
      end
    else
      _missing -> {:error, :price_unavailable}
    end
  end

  # Confirms the credential and records the key's limits without the label or usage.
  defp check_key(state) do
    {result, state} =
      timed(state, %{phase: "key"}, fn ->
        request(state.provider, method: :get, url: "/key", auth: true)
      end)

    case result do
      {:ok, %{"data" => %{} = data}} ->
        remaining = data["limit_remaining"]

        key = %{
          is_free_tier: data["is_free_tier"],
          limit_usd: data["limit"],
          limit_covers_estimate:
            not is_number(remaining) or remaining >= state.preflight.estimated_max_cost_usd,
          rate_limit:
            if(is_map(data["rate_limit"]),
              do: Map.take(data["rate_limit"], ~w(requests interval))
            )
        }

        if key.limit_covers_estimate,
          do: {:ok, put_in(state.preflight[:key], key)},
          else: {:error, :key_limit_too_low, state}

      {:ok, _body} ->
        {:error, :malformed_response, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp embed_documents(state) do
    %{corpus: corpus, gate: gate} = state.fixtures

    corpus
    |> eligible()
    |> Enum.map(&prepare_document(&1, gate))
    |> reduce_ok(state, fn doc, st ->
      with {:ok, vector, st} <- embed_one(st, %{phase: "document", id: doc.id}, doc.text) do
        {:ok, put_in(st.docs[doc.id], vector)}
      end
    end)
  end

  defp embed_full_documents(state) do
    %{corpus: corpus, gate: gate} = state.fixtures

    corpus
    |> eligible()
    |> Enum.filter(&prepare_document(&1, gate).truncated)
    |> reduce_ok(state, fn doc, st ->
      entry = %{phase: "document_full", id: doc["id"]}

      with {:ok, vector, st} <- embed_one(st, entry, document_text(doc)) do
        {:ok, put_in(st.full[doc["id"]], vector)}
      end
    end)
  end

  # Sequential measured passes; every attempt counts, with no warm-up exclusion.
  defp embed_queries(state) do
    %{queries: queries, gate: gate} = state.fixtures
    provider = %{state.provider | timeout_ms: gate["gate"]["query_deadline_ms"]}
    state = %{state | provider: provider}

    for pass <- 1..gate["gate"]["query_passes"], query <- queries do
      {pass, query}
    end
    |> reduce_ok(state, fn {pass, query}, st ->
      {:ok, text} = prepare_query(query["text"], gate)
      entry = %{phase: "query", id: query["id"], pass: pass}

      with {:ok, vector, st} <- embed_one(st, entry, text) do
        [%{elapsed_ms: ms} | _] = st.requests
        st = %{st | query_ms: [ms | st.query_ms]}
        {:ok, if(pass == 1, do: put_in(st.queries[query["id"]], vector), else: st)}
      end
    end)
  end

  defp reduce_ok(items, state, fun) do
    Enum.reduce_while(items, {:ok, state}, fn item, {:ok, st} ->
      case fun.(item, st) do
        {:ok, st} -> {:cont, {:ok, st}}
        {:error, reason, st} -> {:halt, {:error, reason, st}}
      end
    end)
  end

  # The first embedding settles the dimension mode: 1024 values means the parameter was
  # honored; 4096 means it was ignored. A 400 is retried once without the parameter, and
  # only a 4096-value success then establishes that it is unsupported.
  defp embed_one(state, entry, text) do
    entry = Map.put(entry, :input_bytes, byte_size(text))
    {result, state} = timed(state, entry, fn -> embed([text], state.provider) end)

    case {result, state.dimensions_mode} do
      {{:error, {:http_status, 400}}, nil} ->
        provider = %{state.provider | send_dimensions: false, expected_length: 4096}

        {retry, state} =
          timed(%{state | provider: provider}, entry, fn -> embed([text], provider) end)

        with {:ok, vector, state} <- settle(retry, state, "unsupported") do
          {:ok, vector, confirm_rejection(state)}
        end

      {result, nil} ->
        settle(result, state, nil)

      {{:ok, %{vectors: [vector]}}, _mode} ->
        {:ok, vector, state}

      {{:error, reason}, _mode} ->
        {:error, reason, state}
    end
  end

  # The 400 counts as a dimensions rejection only after the retry without the parameter
  # returned 4096 values; until then it keeps its HTTP label.
  defp confirm_rejection(%{requests: [retry, rejected | rest]} = state) do
    %{state | requests: [retry, %{rejected | outcome: "dimensions_rejected"} | rest]}
  end

  defp settle({:ok, %{vectors: [vector], returned_length: length}}, state, mode) do
    mode = mode || if(length == 1024, do: "requested", else: "ignored")
    provider = %{state.provider | expected_length: length}
    {:ok, vector, %{state | dimensions_mode: mode, provider: provider}}
  end

  defp settle({:error, reason}, state, _mode), do: {:error, reason, state}

  # Runs one request, records its allowlisted outcome and samples client RSS.
  defp timed(state, entry, fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    elapsed = System.monotonic_time(:millisecond) - started

    outcome =
      case result do
        {:ok, %{vectors: _} = ok} ->
          %{
            outcome: "ok",
            returned_length: ok.returned_length,
            prompt_tokens: ok.prompt_tokens,
            cost_usd: ok.cost_usd,
            model: ok.model,
            provider: ok.provider
          }

        {:ok, _body} ->
          %{outcome: "ok"}

        {:error, reason} ->
          %{outcome: error_label(reason)}
      end

    entry = entry |> Map.merge(outcome) |> Map.put(:elapsed_ms, elapsed)
    rss = rss_kib()
    {result, %{state | requests: [entry | state.requests], rss_peak: max(rss, state.rss_peak)}}
  end

  ## Report

  defp report({:error, reason, state}, baseline) do
    state
    |> base_report(baseline)
    |> Map.merge(%{
      status: if(blocker(reason), do: "blocked", else: "failed"),
      blocker: blocker(reason),
      error: error_label(reason),
      gates: [gate("provider_calls", "all requests succeed", error_label(reason), false)]
    })
  end

  defp report({:ok, state}, baseline) do
    %{gate: gate, queries: queries} = state.fixtures
    results = Enum.map(queries, &query_result(&1, state))
    long = Enum.filter(results, & &1.long_input)
    requests = Enum.reverse(state.requests)

    measured = %{
      macro_recall: mean(Enum.map(results, & &1.recall)),
      long_recall_bounded: mean(Enum.map(long, & &1.recall)),
      long_recall_full: mean(Enum.map(long, & &1.recall_full)),
      query_p95_ms: p95(state.query_ms),
      query_max_ms: Enum.max(state.query_ms),
      document_max_ms:
        Enum.max(for %{phase: "document" <> _, elapsed_ms: ms} <- requests, do: ms),
      incremental_rss_mib: (state.rss_peak - baseline) / 1024,
      models: distinct(requests, :model),
      upstreams: distinct(requests, :provider),
      usage: usage(requests, state)
    }

    gates = gates(results, long, measured, gate)

    state
    |> base_report(baseline)
    |> Map.merge(%{
      status: if(Enum.all?(gates, & &1.passed), do: "passed", else: "failed"),
      blocker: nil,
      summary: %{
        macro_recall_at_k: measured.macro_recall,
        long_input_queries: Enum.map(long, & &1.id),
        long_input_recall_bounded: measured.long_recall_bounded,
        long_input_recall_full: measured.long_recall_full
      },
      queries: Enum.map(results, &Map.drop(&1, [:scores, :scores_full])),
      scores: %{
        bounded: Map.new(results, &{&1.id, &1.scores}),
        full_long_documents: Map.new(results, &{&1.id, &1.scores_full})
      },
      latency: %{
        query_ms: Enum.reverse(state.query_ms),
        query_p95_ms: measured.query_p95_ms,
        query_max_ms: measured.query_max_ms,
        document_max_ms: measured.document_max_ms,
        queries_per_second: length(state.query_ms) * 1000 / max(Enum.sum(state.query_ms), 1),
        concurrency: 1,
        http_retries: false
      },
      gates: gates
    })
  end

  defp query_result(query, state) do
    k = state.fixtures.gate["gate"]["k"]
    relevant = query["relevant"]
    vector = state.queries[query["id"]]
    ranked = rank(vector, state.docs)
    ranked_full = rank(vector, Map.merge(state.docs, state.full))
    top = ranked |> Enum.take(k) |> Enum.map(&elem(&1, 0))
    hits = Enum.filter(top, &(&1 in relevant))
    tip_of = Map.new(state.fixtures.corpus, &{&1["id"], &1["parent_id"] || &1["id"]})

    %{
      id: query["id"],
      category: query["category"],
      relevant: relevant,
      top_k: top,
      hits: hits,
      recall: recall(Enum.map(ranked, &elem(&1, 0)), relevant, k),
      recall_full: recall(Enum.map(ranked_full, &elem(&1, 0)), relevant, k),
      long_input: Enum.any?(relevant, &Map.has_key?(state.full, &1)),
      top_k_tips: top |> Enum.map(&tip_of[&1]) |> Enum.uniq(),
      relevant_tips_matched: hits |> Enum.map(&tip_of[&1]) |> Enum.uniq(),
      scores: Map.new(ranked),
      scores_full: Map.take(Map.new(ranked_full), Map.keys(state.full))
    }
  end

  defp gates(results, long, measured, gate) do
    %{"k" => k} = g = gate["gate"]
    budget = gate["budget"]
    usage = measured.usage
    loss = measured.long_recall_full - measured.long_recall_bounded
    every_hit = &Enum.all?(&1, fn result -> result.hits != [] end)
    hit_count = &Enum.count(&1, fn result -> result.hits != [] end)

    [
      gate(
        "provider_calls",
        "all requests succeed",
        usage.failed_requests,
        usage.failed_requests == 0
      ),
      gate(
        "every_query_top_k_hit",
        "each query has a relevant top-#{k} hit",
        hit_count.(results),
        every_hit.(results)
      ),
      gate(
        "macro_recall_at_k",
        ">= #{g["min_macro_recall"]}",
        measured.macro_recall,
        measured.macro_recall >= g["min_macro_recall"]
      ),
      gate(
        "long_input_top_k_hit",
        "each long-input query keeps a top-#{k} hit",
        hit_count.(long),
        every_hit.(long)
      ),
      gate(
        "long_input_recall_loss",
        "<= #{g["long_input_max_recall_loss"]}",
        loss,
        loss <= g["long_input_max_recall_loss"] + 1.0e-9
      ),
      gate(
        "query_p95_ms",
        "<= #{g["query_p95_ms"]}",
        measured.query_p95_ms,
        measured.query_p95_ms <= g["query_p95_ms"]
      ),
      gate(
        "query_deadline_ms",
        "<= #{g["query_deadline_ms"]}",
        measured.query_max_ms,
        measured.query_max_ms <= g["query_deadline_ms"]
      ),
      gate(
        "document_deadline_ms",
        "<= #{g["document_deadline_ms"]}",
        measured.document_max_ms,
        measured.document_max_ms <= g["document_deadline_ms"]
      ),
      gate(
        "incremental_rss_mib",
        "<= #{g["max_incremental_rss_mib"]}",
        measured.incremental_rss_mib,
        measured.incremental_rss_mib <= g["max_incremental_rss_mib"]
      ),
      gate(
        "candidate_identity",
        "every response names the requested model and pinned upstream",
        %{models: measured.models, upstreams: measured.upstreams},
        match?([_], measured.models) and match?([_], measured.upstreams)
      ),
      gate(
        "request_budget",
        "<= #{budget["max_requests"]} requests",
        usage.requests,
        usage.requests <= budget["max_requests"]
      ),
      gate(
        "token_budget",
        "<= #{budget["max_input_tokens"]} prompt tokens",
        usage.prompt_tokens,
        usage.prompt_tokens <= budget["max_input_tokens"]
      ),
      gate(
        "cost_budget",
        "<= US$#{budget["max_cost_usd"]}",
        usage.cost_usd,
        usage.cost_usd <= budget["max_cost_usd"]
      )
    ]
  end

  defp distinct(requests, key) do
    requests |> Enum.map(& &1[key]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp base_report(state, baseline) do
    %{gate: gate, corpus: corpus, hashes: hashes} = state.fixtures
    requests = Enum.reverse(state.requests)

    long_inputs =
      for doc <- eligible(corpus),
          prepared = prepare_document(doc, gate),
          prepared.truncated do
        %{
          id: doc["id"],
          full_bytes: prepared.full_bytes,
          bounded_bytes: byte_size(prepared.text),
          dropped_bytes: prepared.full_bytes - byte_size(prepared.text)
        }
      end

    %{
      probe: "issue-54 search embedding gate",
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      code: code_identity(),
      fixtures: %{gate_version: gate["version"], hashes: hashes},
      model: gate["model"],
      provider: Map.take(gate["provider"], ["name", "base_url", "routing"]),
      preparation: gate["preparation"],
      dimensions: %{
        requested: gate["dimensions"],
        mode: state.dimensions_mode,
        returned_lengths: distinct(requests, :returned_length)
      },
      preflight: state.preflight,
      requests: requests,
      usage: usage(requests, state),
      memory: %{
        baseline_rss_kib: baseline,
        peak_rss_kib: state.rss_peak,
        incremental_mib: (state.rss_peak - baseline) / 1024,
        method: "client OS RSS sampled after every request; hosted GPU memory is not observable"
      },
      long_inputs: long_inputs
    }
  end

  defp usage(requests, state) do
    tokens = requests |> Enum.map(&(&1[:prompt_tokens] || 0)) |> Enum.sum()
    reported = requests |> Enum.map(& &1[:cost_usd]) |> Enum.reject(&is_nil/1)
    price = get_in(state.preflight, [:endpoint, :prompt_price_usd_per_token])

    %{
      requests: length(requests),
      failed_requests: Enum.count(requests, &(&1.outcome not in ["ok", "dimensions_rejected"])),
      prompt_tokens: tokens,
      cost_usd: Enum.sum(reported),
      cost_source: if(reported == [], do: "none reported", else: "provider-reported usage.cost"),
      estimated_cost_usd: price && tokens * price
    }
  end

  defp gate(name, threshold, value, passed),
    do: %{name: name, threshold: threshold, value: value, passed: passed}

  defp mean([]), do: 1.0
  defp mean(values), do: Enum.sum(values) / length(values)

  defp blocker(:missing_credentials), do: "missing_credentials"
  defp blocker({:http_status, status}) when status in [401, 402, 403, 429], do: "http_#{status}"
  defp blocker(:transport), do: "transport"
  defp blocker(:pinned_provider_unlisted), do: "pinned_provider_unlisted"
  defp blocker(:price_unavailable), do: "price_unavailable"
  defp blocker(:key_limit_too_low), do: "key_limit_too_low"
  defp blocker({:budget, _message}), do: "budget"
  defp blocker(_reason), do: nil

  defp error_label({:http_status, status}), do: "http_#{status}"
  defp error_label({:vector_length, length}), do: "vector_length_#{length}"
  defp error_label({:budget, message}), do: "budget: #{message}"
  defp error_label(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp code_identity do
    sha = git(["rev-parse", "HEAD"])
    %{sha: sha, dirty: git(["status", "--porcelain"]) != ""}
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _error -> "unknown"
    end
  end

  defp rss_kib do
    case System.cmd("ps", ["-o", "rss=", "-p", System.pid()]) do
      {out, 0} -> out |> String.trim() |> String.to_integer()
      _error -> 0
    end
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
