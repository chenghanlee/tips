defmodule Tips.Content.Media.CloudflareStream do
  @moduledoc """
  Video reservations in Cloudflare Stream, through its API.

  Each call is one bounded request: 5-second connect and receive timeouts, no
  retries or redirects. Errors carry a status or `:transport`, never a URL,
  header or credential. The upload URL is a bearer capability: never log it.
  """

  alias Tips.ProviderConfig

  @api "https://api.cloudflare.com/client/v4/accounts"

  # Read the uid from this header, not from `Location`; see "Managed video" in the
  # backend design.
  @uid_header "stream-media-id"

  @type error :: {:http, pos_integer()} | :transport | :incomplete

  @doc """
  Builds the request client. Options, over the application environment for
  this module:

    * `:plug` - a `Req` plug in place of the network, for tests;
    * `:settings` - a map of `:account_id` and `:api_token`. Without it, reads
      `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_STREAM_API_TOKEN` and raises when
      one is missing.
  """
  @spec client!(keyword()) :: Req.Request.t()
  def client!(opts \\ []) do
    opts = Keyword.merge(Application.get_env(:tips, __MODULE__, []), opts)
    settings = opts[:settings] || provider_settings()

    Req.new(
      plug: opts[:plug],
      base_url: "#{@api}/#{settings.account_id}/stream",
      auth: {:bearer, settings.api_token},
      retry: false,
      redirect: false,
      decode_body: false,
      receive_timeout: 5_000,
      connect_options: [timeout: 5_000]
    )
  end

  defp provider_settings do
    %{
      account_id: ProviderConfig.fetch!("CLOUDFLARE_ACCOUNT_ID"),
      api_token: ProviderConfig.fetch!("CLOUDFLARE_STREAM_API_TOKEN")
    }
  end

  @doc """
  Reserves a private direct creator tus upload of `length` bytes, at most 180
  seconds long, that expires at `expiry`. `name` labels it for operators.

  Returns the Stream uid and the upload URL. Only a response is definite: on
  `:transport`, or a created response without a uid or URL (`:incomplete`),
  the reservation may exist at Stream.
  """
  @spec reserve(Req.Request.t(), pos_integer(), DateTime.t(), String.t()) ::
          {:ok, %{uid: String.t(), url: String.t()}} | {:error, error()}
  def reserve(client, length, expiry, name) do
    metadata =
      Enum.join(
        [
          "maxDurationSeconds " <> Base.encode64("180"),
          "requiresignedurls",
          "expiry " <> Base.encode64(DateTime.to_iso8601(expiry)),
          "name " <> Base.encode64(name)
        ],
        ","
      )

    client
    |> Req.post(
      url: "",
      params: [direct_user: true],
      headers: [
        tus_resumable: "1.0.0",
        upload_length: Integer.to_string(length),
        upload_metadata: metadata
      ]
    )
    |> reservation()
  end

  defp reservation({:ok, %Req.Response{status: 201} = response}) do
    case {Req.Response.get_header(response, @uid_header),
          Req.Response.get_header(response, "location")} do
      {[uid], [url]} when uid != "" and url != "" -> {:ok, %{uid: uid, url: url}}
      _missing -> {:error, :incomplete}
    end
  end

  defp reservation({:ok, %Req.Response{status: status}}), do: {:error, {:http, status}}
  defp reservation({:error, _exception}), do: {:error, :transport}
end
