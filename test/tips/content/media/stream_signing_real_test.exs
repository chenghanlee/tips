defmodule Tips.Content.Media.StreamSigningRealTest do
  # Real Stream playback with the development account's signing key. The video is
  # reserved and uploaded directly; no database row is needed. Failures report
  # status codes only, never URLs, tokens or keys.
  use ExUnit.Case, async: false

  alias Tips.Content.Media.{CloudflareStream, StreamSigner}

  @moduletag :real_provider
  @moduletag timeout: 240_000
  @fixture Path.expand("../../../fixtures/videos/two_seconds.mp4", __DIR__)

  setup do
    signer = Application.fetch_env!(:tips, StreamSigner)
    Application.put_env(:tips, StreamSigner, settings: nil)
    client = CloudflareStream.client!(plug: nil, settings: nil)

    on_exit(fn ->
      Application.put_env(:tips, StreamSigner, signer)
    end)

    %{client: client}
  end

  defp status(url), do: response(url).status

  defp response(url) do
    {:ok, response} = Req.get(url, retry: false, redirect: false, decode_body: false)
    response
  end

  # The first URI line of a playlist, resolved against the playlist's URL.
  defp first_entry(url) do
    response = response(url)
    assert response.status == 200

    entry =
      response.body
      |> String.split("\n", trim: true)
      |> Enum.find(&(not String.starts_with?(&1, "#")))

    url |> URI.merge(String.trim(entry)) |> URI.to_string()
  end

  defp manifest(iframe_url),
    do: String.replace_suffix(iframe_url, "/iframe", "/manifest/video.m3u8")

  # Polls every 3 seconds for at most 120 seconds.
  defp await_ready(client, uid, attempts \\ 40) do
    case CloudflareStream.status(client, uid) do
      {:ok, %{ready_to_stream: true}} ->
        :ok

      {:ok, %{state: state}} when state != :error and attempts > 1 ->
        Process.sleep(3_000)
        await_ready(client, uid, attempts - 1)

      other ->
        flunk("video never became ready: #{inspect(other)}")
    end
  end

  test "only fresh tokens signed with the account key play", %{client: client} do
    file = File.read!(@fixture)
    expiry = DateTime.add(DateTime.utc_now(:second), 3600)

    assert {:ok, %{uid: uid, url: upload_url}} =
             CloudflareStream.reserve(client, byte_size(file), expiry, "tips-signing-test")

    on_exit(fn ->
      assert :ok = CloudflareStream.delete(client, uid)
      assert {:error, {:http, 404}} = CloudflareStream.status(client, uid)
    end)

    assert {:ok, %{status: 204}} =
             Req.patch(upload_url,
               body: file,
               headers: [
                 tus_resumable: "1.0.0",
                 upload_offset: "0",
                 content_type: "application/offset+octet-stream"
               ],
               retry: false
             )

    :ok = await_ready(client, uid)

    now = DateTime.utc_now()
    iframe = StreamSigner.destination(:iframe, uid, now)
    thumbnail = StreamSigner.destination(:thumbnail, uid, now)

    segment = iframe |> manifest() |> first_entry() |> first_entry()
    assert status(segment) == 200
    thumbnail_response = response(thumbnail)
    assert thumbnail_response.status == 200
    assert Req.Response.get_header(thumbnail_response, "content-type") == ["image/jpeg"]

    # Unsigned: the bare uid in place of the token.
    %{customer_code: code, kid: kid} = StreamSigner.settings!()
    bare = "https://customer-#{code}.cloudflarestream.com/#{uid}"

    for path <- ~w(manifest/video.m3u8 thumbnails/thumbnail.jpg iframe) do
      assert {path, status("#{bare}/#{path}")} == {path, 401}
    end

    expired = StreamSigner.destination(:iframe, uid, DateTime.add(now, -7200))
    assert status(manifest(expired)) == 401

    # A fresh key that carries the account key's id.
    {_modules, forged} = JOSE.JWK.to_map(JOSE.JWK.generate_key({:rsa, 2048}))
    forged = forged |> Map.put("kid", kid) |> JSON.encode!() |> Base.encode64()

    Application.put_env(:tips, StreamSigner,
      settings: %{customer_code: code, signing_key: forged}
    )

    assert status(manifest(StreamSigner.destination(:iframe, uid, now))) == 401
  end
end
