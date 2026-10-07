defmodule Tips.Content.Search.EmbeddingProvider do
  @moduledoc """
  The embedding runtime that search uses, behind one behaviour. Callers use
  only this module; `config :tips, Tips.Content.Search.EmbeddingProvider,
  implementation: module` selects the module that makes the requests. The one
  implementation is `Tips.Content.Search.EmbeddingProvider.OpenRouter`, which
  reads its model, host and query instruction from its own configuration.

  ## Swapping the runtime

  Production runs one model on one host at a time. Changing the
  implementation, model or host changes every vector, so every stored
  document must be embedded again; follow "Changing the model" in
  `Tips.Content.Search.Embeddings`. Changing the dimensions also needs a
  migration of the `embedding` columns and `Tips.Content.Search.Vector`.

  ## Contract

  Documents are plain text of at most 30,000 UTF-8 bytes, never truncated.
  Queries are at most 1024 bytes. Invalid or oversized input is rejected here,
  before the implementation is called.

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
    * `:contract` - a response for another model or host, or a vector with
      another number of values than requested;
    * `:malformed` - anything else that is not one embedding of finite
      numbers, not all zero.

  A returned vector is the L2-normalized response as a pgvector literal.
  """

  alias Tips.Content.Search.Vector

  @max_document_bytes 30_000
  @max_query_bytes 1024

  @type error ::
          :invalid_input
          | :too_large
          | :busy
          | {:http, pos_integer()}
          | :transport
          | :deadline
          | :contract
          | :malformed

  @typedoc "The implementation and its own client."
  @type client :: {module(), term()}

  @doc """
  Builds the implementation's client. Raises when its configuration, such as
  the API key, is missing. `opts` go over the application environment of the
  implementation; `:deadline` is in milliseconds, capped at 30,000.
  """
  @callback client!(opts :: keyword()) :: term()

  @doc "Embeds one valid document."
  @callback embed_document(client :: term(), text :: String.t()) ::
              {:ok, Vector.t()} | {:error, error()}

  @doc "Embeds one valid reader query, adding any instruction the model needs."
  @callback embed_query(client :: term(), query :: String.t()) ::
              {:ok, Vector.t()} | {:error, error()}

  @doc "Builds the configured implementation's client. See `c:client!/1`."
  @spec client!(keyword()) :: client()
  def client!(opts \\ []) do
    implementation = Application.fetch_env!(:tips, __MODULE__)[:implementation]
    {implementation, implementation.client!(opts)}
  end

  @doc "The largest document, in UTF-8 bytes, that `embed_document/2` accepts."
  @spec max_document_bytes() :: pos_integer()
  def max_document_bytes, do: @max_document_bytes

  @doc "The largest query, in UTF-8 bytes, that `embed_query/2` accepts."
  @spec max_query_bytes() :: pos_integer()
  def max_query_bytes, do: @max_query_bytes

  @doc "Embeds one document. See the module documentation for errors."
  @spec embed_document(client(), String.t()) :: {:ok, Vector.t()} | {:error, error()}
  def embed_document({implementation, client}, text) do
    with :ok <- input(text, @max_document_bytes), do: implementation.embed_document(client, text)
  end

  @doc "Embeds one reader query. See the module documentation for errors."
  @spec embed_query(client(), String.t()) :: {:ok, Vector.t()} | {:error, error()}
  def embed_query({implementation, client}, query) do
    with :ok <- input(query, @max_query_bytes), do: implementation.embed_query(client, query)
  end

  defp input(text, max_bytes) when is_binary(text) and byte_size(text) > max_bytes,
    do: {:error, :too_large}

  defp input(text, _max_bytes) when is_binary(text) do
    if String.valid?(text) and String.trim(text) != "", do: :ok, else: {:error, :invalid_input}
  end

  defp input(_text, _max_bytes), do: {:error, :invalid_input}
end
