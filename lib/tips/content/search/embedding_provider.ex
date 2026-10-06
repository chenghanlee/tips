defmodule Tips.Content.Search.EmbeddingProvider do
  @moduledoc """
  The selected embedding runtime: `qwen/qwen3-embedding-8b` through OpenRouter,
  served only by DeepInfra, with fallbacks disabled so vectors never mix.

  The ten-query gate fixed this runtime (`test/fixtures/search_probe/gate-v2.json`,
  evidence retained on #234): 1024 requested dimensions, and plain-text
  documents of at most 30,000 UTF-8 bytes, never truncated. Queries are at
  most 1024 bytes and are sent after the gate's retrieval instruction,
  `"Instruct: Given a web search query, retrieve relevant passages that answer the query\\nQuery:"`,
  with nothing between the instruction and the query.

  `client!/1` resolves configuration once; `embed_document/2` and
  `embed_query/2` make at most one request with it. There are no retries or
  redirects, so text is sent once. One deadline of at most 30 seconds covers
  the wait for shared capacity (`Tips.Content.Search.ProviderCapacity`),
  connection pool wait, connect, send, receive and decoding. On expiry the
  request process is killed. A request the provider already received cannot
  be recalled. The request process is linked: if it crashes, so does the
  caller, and a caller that exits takes it along.

  Errors are classifications only. They never carry credentials, input text,
  response bodies or headers:

    * `:invalid_input` - not valid UTF-8, or blank; no request is made;
    * `:too_large` - a document over 30,000 bytes or a query over 1024;
      no request is made;
    * `:busy` - no shared capacity freed within the queue wait; no request
      is made;
    * `{:http, status}` - any status other than 200;
    * `:transport` - the connection failed;
    * `:deadline` - the deadline expired;
    * `:contract` - a response for another model or provider, or a vector
      that is not exactly 1024 values;
    * `:malformed` - anything else that is not one embedding of finite
      numbers, not all zero.

  A returned vector is the L2-normalized response as a pgvector literal.
  """

  alias Tips.Content.Search.{ProviderCapacity, Vector}
  alias Tips.ProviderConfig

  @base_url "https://openrouter.ai/api/v1"
  @model "qwen/qwen3-embedding-8b"
  @upstream "DeepInfra"
  @routing %{only: ["deepinfra"], allow_fallbacks: false}
  @dimensions 1024
  @max_document_bytes 30_000
  @max_query_bytes 1024
  @query_instruction "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:"
  @deadline 30_000

  @type error ::
          :invalid_input
          | :too_large
          | :busy
          | {:http, pos_integer()}
          | :transport
          | :deadline
          | :contract
          | :malformed

  @doc """
  Builds the request client, reading `OPENROUTER_API_KEY` when no key is given.

  Raises when the key is missing. Options, over the application environment
  for this module:

    * `:api_key` - the OpenRouter key;
    * `:plug` - a `Req` plug in place of the network, for tests;
    * `:deadline` - milliseconds; values above 30,000 are capped.

  The endpoint, model, routing, dimensions, retry and redirect policy cannot
  be overridden.
  """
  @spec client!(keyword()) :: Req.Request.t()
  def client!(opts \\ []) do
    opts = Keyword.merge(Application.get_env(:tips, __MODULE__, []), opts)
    deadline = min(Keyword.get(opts, :deadline, @deadline), @deadline)
    api_key = opts[:api_key] || ProviderConfig.fetch!("OPENROUTER_API_KEY")

    opts
    |> Keyword.take([:plug])
    |> Req.new()
    |> Req.merge(
      method: :post,
      base_url: @base_url,
      url: "/embeddings",
      auth: {:bearer, api_key},
      retry: false,
      redirect: false,
      decode_body: false,
      receive_timeout: deadline,
      connect_options: [timeout: deadline]
    )
    |> Req.Request.put_private(:deadline, deadline)
  end

  @doc "The largest query, in UTF-8 bytes, that `embed_query/2` accepts."
  @spec max_query_bytes() :: pos_integer()
  def max_query_bytes, do: @max_query_bytes

  @doc "Embeds one document. See the module documentation for errors."
  @spec embed_document(Req.Request.t(), String.t()) :: {:ok, Vector.t()} | {:error, error()}
  def embed_document(%Req.Request{} = client, text) do
    with :ok <- input(text, @max_document_bytes), do: request(client, text)
  end

  @doc """
  Embeds one reader query after the retrieval instruction. See the module
  documentation for errors.
  """
  @spec embed_query(Req.Request.t(), String.t()) :: {:ok, Vector.t()} | {:error, error()}
  def embed_query(%Req.Request{} = client, query) do
    with :ok <- input(query, @max_query_bytes), do: request(client, @query_instruction <> query)
  end

  defp input(text, max_bytes) when is_binary(text) and byte_size(text) > max_bytes,
    do: {:error, :too_large}

  defp input(text, _max_bytes) when is_binary(text) do
    if String.valid?(text) and String.trim(text) != "", do: :ok, else: {:error, :invalid_input}
  end

  defp input(_text, _max_bytes), do: {:error, :invalid_input}

  defp request(client, text) do
    body = %{model: @model, input: [text], dimensions: @dimensions, provider: @routing}
    deadline = System.monotonic_time(:millisecond) + Req.Request.get_private(client, :deadline)
    ProviderCapacity.run(deadline, fn -> send_request(client, body, deadline) end)
  end

  defp send_request(client, body, deadline) do
    task = Task.async(fn -> client |> Req.request(json: body) |> response() end)
    time_left = max(deadline - System.monotonic_time(:millisecond), 0)

    case Task.yield(task, time_left) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :deadline}
      {:exit, reason} -> exit(reason)
    end
  end

  defp response({:ok, %Req.Response{status: 200, body: body}}), do: decode(body)
  defp response({:ok, %Req.Response{status: status}}), do: {:error, {:http, status}}
  defp response({:error, %Req.TransportError{reason: :timeout}}), do: {:error, :deadline}
  defp response({:error, _exception}), do: {:error, :transport}

  @doc """
  Decodes a 200 response body as `embed_document/2` and `embed_query/2` do:
  the vector, `{:error, :contract}` or `{:error, :malformed}`.
  """
  @spec decode(String.t()) :: {:ok, Vector.t()} | {:error, :contract | :malformed}
  def decode(body) do
    case JSON.decode(body) do
      {:ok,
       %{
         "data" => [%{"index" => 0, "embedding" => values}],
         "model" => model,
         "provider" => upstream
       }}
      when is_list(values) and is_binary(model) and is_binary(upstream) ->
        vector(values, model, upstream)

      _not_one_embedding ->
        {:error, :malformed}
    end
  end

  defp vector(values, model, upstream) do
    if same?(model, @model) and same?(upstream, @upstream) and length(values) == @dimensions do
      case Vector.literal(values) do
        {:ok, vector} -> {:ok, vector}
        :error -> {:error, :malformed}
      end
    else
      {:error, :contract}
    end
  end

  defp same?(returned, expected), do: String.downcase(returned) == String.downcase(expected)
end
