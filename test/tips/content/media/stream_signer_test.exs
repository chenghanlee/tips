defmodule Tips.Content.Media.StreamSignerTest do
  # Not async: the failure case replaces this module's and the provider settings.
  use ExUnit.Case, async: false

  alias Tips.Content.Media.StreamSigner
  alias Tips.Content.Media.StreamSigner.ConfigError

  @key_path Path.expand("../../../support/fixtures/stream_signing_key.json", __DIR__)

  test "signs exactly the documented claims with RS256, one hour from now" do
    now = ~U[2026-10-14 12:00:00Z]
    url = StreamSigner.destination(:thumbnail, "abc123", now)

    assert "https://customer-synthetic-code.cloudflarestream.com/" <> rest = url
    assert [token, "thumbnails/thumbnail.jpg"] = String.split(rest, "/", parts: 2)

    key = JSON.decode!(File.read!(@key_path))

    assert {true, %JOSE.JWT{fields: claims}, %JOSE.JWS{fields: %{"typ" => "JWT"}}} =
             JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["RS256"], token)

    assert claims == %{
             "sub" => "abc123",
             "kid" => key["kid"],
             "exp" => DateTime.to_unix(now) + 3600,
             "downloadable" => false
           }
  end

  test "a non-RSA key or a blank provider value raises naming only the variable" do
    signer = Application.fetch_env!(:tips, StreamSigner)
    provider = Application.fetch_env!(:tips, Tips.ProviderConfig)

    on_exit(fn ->
      Application.put_env(:tips, StreamSigner, signer)
      Application.put_env(:tips, Tips.ProviderConfig, provider)
    end)

    {_modules, ec_key} = JOSE.JWK.to_map(JOSE.JWK.generate_key({:ec, "P-256"}))
    ec_key = ec_key |> Map.put("kid", "ec-kid") |> JSON.encode!() |> Base.encode64()

    Application.put_env(:tips, StreamSigner, settings: %{signer[:settings] | signing_key: ec_key})

    assert_raise ConfigError, "CLOUDFLARE_STREAM_SIGNING_KEY is missing or malformed", fn ->
      StreamSigner.settings!()
    end

    # Without module settings, the values come from the provider configuration.
    Application.put_env(:tips, StreamSigner, [])

    Application.put_env(:tips, Tips.ProviderConfig,
      values: %{
        "CLOUDFLARE_STREAM_CUSTOMER_CODE" => " ",
        "CLOUDFLARE_STREAM_SIGNING_KEY" => signer[:settings].signing_key
      }
    )

    assert_raise ConfigError, "CLOUDFLARE_STREAM_CUSTOMER_CODE is missing or malformed", fn ->
      StreamSigner.destination(:iframe, "abc123", DateTime.utc_now())
    end
  end
end
