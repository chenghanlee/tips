defmodule Tips.Content.Search.EmbeddingProvider.OpenRouter do
  @moduledoc """
  The `Tips.Content.Search.EmbeddingProvider` implementation that calls
  OpenRouter's embeddings API, routed to exactly one host with fallbacks
  disabled so vectors never mix.

  Its runtime comes from `config :tips, Tips.Content.Search.EmbeddingProvider.OpenRouter`:

    * `:model` - the OpenRouter model slug;
    * `:host` - the one OpenRouter provider slug that may serve it;
    * `:upstream` - the provider name a response must report;
    * `:dimensions` - the requested vector size;
    * `:query_instruction` - text sent directly before each query, with
      nothing between it.

  The selected runtime is `qwen/qwen3-embedding-8b` on Nebius at 1024
  dimensions, with the model card's retrieval instruction. The ten-query gate
  chose the model (`test/fixtures/search_probe/gate-v2.json`, evidence on
  #234); #363 measured Nebius
  (`test/fixtures/search_probe/evidence/363-nebius.json`) after DeepInfra
  missed the 30-second document deadline, and #365 kept it.
  """

  @behaviour Tips.Content.Search.EmbeddingProvider

  alias Tips.Content.Search.{ProviderCapacity, Vector}
  alias Tips.ProviderConfig

  @base_url "https://openrouter.ai/api/v1"
  @deadline 30_000

  @doc """
  Builds the request client, reading `OPENROUTER_API_KEY` when no key is given.

  Raises when the key is missing. Options, over the application environment
  for this module:

    * `:api_key` - the OpenRouter key;
    * `:plug` - a `Req` plug in place of the network, for tests;
    * `:deadline` - milliseconds; values above 30,000 are capped.

  Callers cannot override the endpoint, runtime, retry or redirect policy.
  """
  @impl true
  def client!(opts) do
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
    |> Req.Request.put_private(:runtime, runtime())
  end

  @doc "The configured runtime: model, host, upstream, dimensions and query instruction."
  def runtime do
    config = Application.fetch_env!(:tips, __MODULE__)
    Map.new(~w(model host upstream dimensions query_instruction)a, &{&1, config[&1]})
  end

  @impl true
  def embed_document(%Req.Request{} = client, text), do: request(client, text)

  @impl true
  def embed_query(%Req.Request{} = client, query),
    do: request(client, Req.Request.get_private(client, :runtime).query_instruction <> query)

  defp request(client, text) do
    runtime = Req.Request.get_private(client, :runtime)

    body = %{
      model: runtime.model,
      input: [text],
      dimensions: runtime.dimensions,
      provider: %{only: [runtime.host], allow_fallbacks: false}
    }

    deadline = System.monotonic_time(:millisecond) + Req.Request.get_private(client, :deadline)
    ProviderCapacity.run(deadline, fn -> send_request(client, body, runtime, deadline) end)
  end

  defp send_request(client, body, runtime, deadline) do
    task = Task.async(fn -> client |> Req.request(json: body) |> response(runtime) end)
    time_left = max(deadline - System.monotonic_time(:millisecond), 0)

    case Task.yield(task, time_left) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :deadline}
      {:exit, reason} -> exit(reason)
    end
  end

  defp response({:ok, %Req.Response{status: 200, body: body}}, runtime), do: decode(body, runtime)
  defp response({:ok, %Req.Response{status: status}}, _runtime), do: {:error, {:http, status}}

  defp response({:error, %Req.TransportError{reason: :timeout}}, _runtime),
    do: {:error, :deadline}

  defp response({:error, _exception}, _runtime), do: {:error, :transport}

  @doc """
  Decodes a 200 response body as the requests do, for the configured runtime:
  the vector, `{:error, :contract}` or `{:error, :malformed}`.
  """
  @spec decode(String.t(), map()) :: {:ok, Vector.t()} | {:error, :contract | :malformed}
  def decode(body, runtime \\ runtime()) do
    case JSON.decode(body) do
      {:ok,
       %{
         "data" => [%{"index" => 0, "embedding" => values}],
         "model" => model,
         "provider" => upstream
       }}
      when is_list(values) and is_binary(model) and is_binary(upstream) ->
        vector(values, model, upstream, runtime)

      _not_one_embedding ->
        {:error, :malformed}
    end
  end

  defp vector(values, model, upstream, runtime) do
    if same?(model, runtime.model) and same?(upstream, runtime.upstream) and
         length(values) == runtime.dimensions do
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
