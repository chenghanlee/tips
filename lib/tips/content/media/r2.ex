defmodule Tips.Content.Media.R2 do
  @moduledoc """
  Image objects in the R2 bucket, through its S3 API.

  Each call is one bounded request: no retries or redirects, and a hard bound
  over the whole request, `:call_timeout` (default 30 s), past which the
  request is killed and the call returns `{:error, :timeout}`.
  Errors carry a status, `:transport` or `:timeout`, never a URL, header or
  credential. A transport error or timeout leaves the outcome unknown: the
  object may exist.
  """

  require Record

  alias Tips.ProviderConfig

  Record.defrecordp(
    :xml_text,
    :xmlText,
    Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
  )

  @cache_control "public, max-age=3600, must-revalidate"
  @list_page 10

  @type error :: {:http, pos_integer()} | :transport | :timeout

  @typedoc "One page of a listing; `next` continues it, `nil` ends it."
  @type page :: %{
          objects: [%{key: String.t(), last_modified: DateTime.t()}],
          next: String.t() | nil
        }

  @doc """
  Builds the request client. Options, over the application environment for
  this module:

    * `:plug` - a `Req` plug in place of the network, for tests;
    * `:settings` - a map of `:endpoint`, `:bucket`, `:access_key_id` and
      `:secret_access_key`. Without it, reads `R2_ENDPOINT`, `R2_BUCKET`,
      `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY` and raises when one is
      missing;
    * `:call_timeout` - the bound over each call in milliseconds, default
      30,000.
  """
  @spec client!(keyword()) :: Req.Request.t()
  def client!(opts \\ []) do
    opts = Keyword.merge(Application.get_env(:tips, __MODULE__, []), opts)
    settings = opts[:settings] || provider_settings()

    Req.new(
      plug: opts[:plug],
      base_url: "#{String.trim_trailing(settings.endpoint, "/")}/#{settings.bucket}",
      aws_sigv4: [
        access_key_id: settings.access_key_id,
        secret_access_key: settings.secret_access_key,
        service: :s3,
        region: "auto"
      ],
      retry: false,
      redirect: false,
      decode_body: false,
      receive_timeout: 30_000,
      connect_options: [timeout: 10_000]
    )
    |> Req.Request.put_private(:call_timeout, Keyword.get(opts, :call_timeout, 30_000))
  end

  defp provider_settings do
    %{
      endpoint: ProviderConfig.fetch!("R2_ENDPOINT"),
      bucket: ProviderConfig.fetch!("R2_BUCKET"),
      access_key_id: ProviderConfig.fetch!("R2_ACCESS_KEY_ID"),
      secret_access_key: ProviderConfig.fetch!("R2_SECRET_ACCESS_KEY")
    }
  end

  @doc "Stores `body` at `key` with the given Content-Type and the media cache policy."
  @spec put(Req.Request.t(), String.t(), iodata(), String.t()) :: :ok | {:error, error()}
  def put(client, key, body, content_type) do
    bounded(client, fn ->
      Req.put(client,
        url: "/" <> key,
        body: body,
        headers: [content_type: content_type, cache_control: @cache_control]
      )
    end)
    |> result()
  end

  @doc "Deletes the object at `key`. Deleting a missing object, 204 or 404, succeeds."
  @spec delete(Req.Request.t(), String.t()) :: :ok | {:error, error()}
  def delete(client, key) do
    case bounded(client, fn -> Req.delete(client, url: "/" <> key) end) do
      {:ok, %Req.Response{status: 404}} -> :ok
      response -> result(response)
    end
  end

  @doc """
  Lists up to ten objects under `prefix` in key order, continuing after the
  `next` token of an earlier page, or from the start when `token` is `nil`.
  """
  @spec list(Req.Request.t(), String.t(), String.t() | nil) :: {:ok, page()} | {:error, error()}
  def list(client, prefix, token) do
    params =
      [{"list-type", 2}, {"prefix", prefix}, {"max-keys", @list_page}] ++
        if(token, do: [{"continuation-token", token}], else: [])

    case bounded(client, fn -> Req.get(client, url: "/", params: params) end) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, page(body)}
      response -> result(response)
    end
  end

  # The request runs in a task so the bound covers connection checkout, connect,
  # sending and receiving. A killed request leaves its outcome unknown.
  defp bounded(client, request) do
    task = Task.async(request)

    case Task.yield(task, Req.Request.get_private(client, :call_timeout)) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, response} -> response
      nil -> {:error, :timeout}
      {:exit, reason} -> exit(reason)
    end
  end

  defp result({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok
  defp result({:ok, %Req.Response{status: status}}), do: {:error, {:http, status}}
  defp result({:error, :timeout}), do: {:error, :timeout}
  defp result({:error, _exception}), do: {:error, :transport}

  # A body that is not XML exits, like any other unexpected provider reply.
  # Entities are refused: the listing needs only the predefined ones.
  defp page(body) do
    {doc, _rest} =
      :xmerl_scan.string(:binary.bin_to_list(body), quiet: true, allow_entities: false)

    objects =
      for object <- :xmerl_xpath.string(~c"/ListBucketResult/Contents", doc) do
        {:ok, last_modified, 0} = DateTime.from_iso8601(text(object, "LastModified"))
        %{key: text(object, "Key"), last_modified: last_modified}
      end

    next =
      case text(doc, "/ListBucketResult/NextContinuationToken") do
        "" -> nil
        token -> token
      end

    %{objects: objects, next: next}
  end

  defp text(node, path) do
    ~c"#{path}/text()"
    |> :xmerl_xpath.string(node)
    |> Enum.map_join(&(&1 |> xml_text(:value) |> List.to_string()))
  end
end
