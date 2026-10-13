defmodule Tips.Content.Media.StreamSigner do
  @moduledoc """
  Signed Cloudflare Stream destinations for a video Tips has already authorized.

  Each token is signed locally with the account's signing key and expires one
  hour after `now`. There is no unsigned or other-host fallback: missing or
  malformed settings raise `ConfigError`. Tokens and signed URLs are bearer
  capabilities: never log them.
  """

  alias Tips.ProviderConfig

  @lifetime_s 3600
  @code_variable "CLOUDFLARE_STREAM_CUSTOMER_CODE"
  @key_variable "CLOUDFLARE_STREAM_SIGNING_KEY"

  # A DNS label: it becomes part of the `customer-<code>` host.
  @customer_code ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/

  defmodule ConfigError do
    @moduledoc "Signing settings are missing or malformed. The message names the variable only."
    defexception [:message]
  end

  @type settings :: %{customer_code: String.t(), kid: String.t(), jwk: JOSE.JWK.t()}

  @doc """
  Returns the signed `:iframe` or `:thumbnail` URL for the Stream video `uid`,
  valid until `now` plus one hour. Raises `ConfigError` when the settings are
  unusable.
  """
  @spec destination(:iframe | :thumbnail, String.t(), DateTime.t()) :: String.t()
  def destination(kind, uid, %DateTime{} = now) when is_binary(uid) do
    %{customer_code: code, kid: kid, jwk: jwk} = settings!()

    claims = %{
      "sub" => uid,
      "kid" => kid,
      "exp" => DateTime.to_unix(now) + @lifetime_s,
      "downloadable" => false
    }

    {_modules, token} = jwk |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()
    "https://customer-#{code}.cloudflarestream.com/#{token}/#{path(kind)}"
  end

  defp path(:iframe), do: "iframe"
  defp path(:thumbnail), do: "thumbnails/thumbnail.jpg"

  @doc """
  Returns the validated settings: the customer code, and the RSA private key
  with its `kid`.

  Reads `settings` (`:customer_code`, `:signing_key`) from the application
  environment for this module, or else `CLOUDFLARE_STREAM_CUSTOMER_CODE` and
  `CLOUDFLARE_STREAM_SIGNING_KEY`. The key is base64 JSON of a JWK carrying
  `kid`, as Stream's signing-key API returns it.
  """
  @spec settings!() :: settings()
  def settings! do
    settings =
      Application.get_env(:tips, __MODULE__, [])[:settings] ||
        %{
          customer_code: provider_value(@code_variable),
          signing_key: provider_value(@key_variable)
        }

    {kid, jwk} = signing_key!(settings.signing_key)
    %{customer_code: customer_code!(settings.customer_code), kid: kid, jwk: jwk}
  end

  # `ProviderConfig.fetch!/1` raises for a blank value, naming the variable.
  defp provider_value(name) do
    ProviderConfig.fetch!(name)
  rescue
    RuntimeError -> reraise ConfigError, [message: invalid(name)], __STACKTRACE__
  end

  defp customer_code!(code) when is_binary(code) do
    if code =~ @customer_code, do: code, else: raise(ConfigError, invalid(@code_variable))
  end

  defp customer_code!(_code), do: raise(ConfigError, invalid(@code_variable))

  defp signing_key!(encoded) do
    case decode_signing_key(encoded) do
      {:ok, kid, jwk} -> {kid, jwk}
      :error -> raise ConfigError, invalid(@key_variable)
    end
  end

  # Decoding errors can quote the key, so none of them is kept or logged.
  defp decode_signing_key(encoded) do
    with true <- is_binary(encoded),
         {:ok, json} <- Base.decode64(String.trim(encoded), padding: false),
         {:ok, %{"kty" => "RSA", "d" => _, "kid" => kid} = map} when is_binary(kid) <-
           JSON.decode(json),
         false <- String.trim(kid) == "",
         %JOSE.JWK{kty: {:jose_jwk_kty_rsa, private_key}} = jwk
         when elem(private_key, 0) == :RSAPrivateKey <- JOSE.JWK.from_map(map) do
      {:ok, kid, jwk}
    else
      _invalid -> :error
    end
  rescue
    _error in [ArgumentError, CaseClauseError, FunctionClauseError, MatchError, ErlangError] ->
      :error
  end

  defp invalid(name), do: "#{name} is missing or malformed"
end
