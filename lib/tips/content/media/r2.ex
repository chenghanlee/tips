defmodule Tips.Content.Media.R2 do
  @moduledoc """
  Image objects in the R2 bucket, through its S3 API.

  Each call is one bounded request: no retries or redirects, fixed timeouts.
  Errors carry a status or `:transport`, never a URL, header or credential.
  A transport error leaves the outcome unknown: the object may exist.
  """

  alias Tips.ProviderConfig

  @cache_control "public, max-age=3600, must-revalidate"

  @type error :: {:http, pos_integer()} | :transport

  @doc """
  Builds the request client. Options, over the application environment for
  this module:

    * `:plug` - a `Req` plug in place of the network, for tests;
    * `:settings` - a map of `:endpoint`, `:bucket`, `:access_key_id` and
      `:secret_access_key`. Without it, reads `R2_ENDPOINT`, `R2_BUCKET`,
      `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY` and raises when one is
      missing.
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
    client
    |> Req.put(
      url: "/" <> key,
      body: body,
      headers: [content_type: content_type, cache_control: @cache_control]
    )
    |> result()
  end

  @doc "Deletes the object at `key`. Deleting a missing object, 204 or 404, succeeds."
  @spec delete(Req.Request.t(), String.t()) :: :ok | {:error, error()}
  def delete(client, key) do
    case Req.delete(client, url: "/" <> key) do
      {:ok, %Req.Response{status: 404}} -> :ok
      response -> result(response)
    end
  end

  defp result({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok
  defp result({:ok, %Req.Response{status: status}}), do: {:error, {:http, status}}
  defp result({:error, _exception}), do: {:error, :transport}
end
