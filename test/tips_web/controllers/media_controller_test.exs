defmodule TipsWeb.MediaControllerTest do
  # Not async: the fail-closed case replaces the signer's application settings.
  use TipsWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures
  import Tips.VisibilityFixtures

  alias Tips.Accounts
  alias Tips.Content.Media.StreamSigner

  @key_path Path.expand("../../support/fixtures/stream_signing_key.json", __DIR__)
  @host "customer-synthetic-code.cloudflarestream.com"

  defp staged_ready_fixture(user, attrs \\ %{}) do
    staged_video_fixture(
      user,
      Map.merge(
        %{state: :ready, stream_uid: "stream-#{Ecto.UUID.generate()}", duration_s: 2.0},
        attrs
      )
    )
  end

  defp watch(conn, id), do: get(conn, "/media/#{id}/watch")
  defp thumbnail(conn, id), do: get(conn, "/media/#{id}/thumbnail")

  # The verified claims of a signed redirect, after checking its URL shape.
  defp signed_claims(conn, suffix) do
    assert conn.status == 302
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert %URI{scheme: "https", host: @host, path: "/" <> path} = URI.parse(redirected_to(conn))
    assert [token, ^suffix] = String.split(path, "/", parts: 2)

    jwk = JOSE.JWK.from_map(JSON.decode!(File.read!(@key_path)))
    assert {true, %JOSE.JWT{fields: claims}, jws} = JOSE.JWT.verify_strict(jwk, ["RS256"], token)
    assert %JOSE.JWS{alg: {:jose_jws_alg_rsa_pkcs1_v1_5, :RS256}} = jws
    claims
  end

  defp assert_plays(conn, %{id: id, stream_uid: uid}) do
    assert %{"sub" => ^uid} = signed_claims(watch(conn, id), "iframe")
  end

  defp assert_not_found(conn, id) do
    for response <- [watch(conn, id), thumbnail(conn, id)] do
      assert response.status == 404
      assert get_resp_header(response, "cache-control") == ["private, no-store"]
      assert get_resp_header(response, "location") == []
    end
  end

  # Collects the table names this process queries while `fun` runs.
  defp capture_sources(fun) do
    test = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:tips, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test, do: send(test, {handler, metadata.source})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(handler, [])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(handler, sources) do
    receive do
      {^handler, source} -> drain(handler, [source | sources])
    after
      0 -> Enum.reverse(sources)
    end
  end

  test "a public video redirects to signed destinations without readmission", %{conn: conn} do
    video = attached_video_fixture(tip_fixture())
    uid = video.stream_uid
    {watched, sources} = capture_sources(fn -> watch(conn, video.id) end)
    expected_exp = DateTime.to_unix(DateTime.utc_now()) + 3600

    assert %{"sub" => ^uid, "kid" => kid, "exp" => exp, "downloadable" => false} =
             signed_claims(watched, "iframe")

    assert kid == JSON.decode!(File.read!(@key_path))["kid"]
    assert exp in (expected_exp - 5)..expected_exp
    refute "users_tokens" in sources

    assert %{"sub" => ^uid} = signed_claims(thumbnail(conn, video.id), "thumbnails/thumbnail.jpg")

    # A signed-in reader's only token query is the request's own admission.
    reader = log_in_user(conn, user_fixture())
    {watched, sources} = capture_sources(fn -> watch(reader, video.id) end)
    assert %{"sub" => ^uid} = signed_claims(watched, "iframe")
    assert Enum.count(sources, &(&1 == "users_tokens")) == 1
  end

  test "a staged ready video plays only for its author", %{conn: conn} do
    author = user_fixture()
    video = staged_ready_fixture(author)

    assert_plays(log_in_user(conn, author), video)
    assert_not_found(conn, video.id)
    assert_not_found(log_in_user(conn, user_fixture()), video.id)
  end

  test "a hidden tip's video plays for its author and moderators only", %{conn: conn} do
    author = user_fixture()
    tip = tip_fixture(author)
    video = attached_video_fixture(tip)
    put_marker!(tip, :hidden)

    assert_plays(log_in_user(conn, author), video)
    assert_plays(log_in_user(conn, moderator!(user_fixture())), video)
    assert_not_found(log_in_user(conn, user_fixture()), video.id)
    assert_not_found(conn, video.id)
  end

  test "a live review's video plays for anyone under a hidden or deleted tip", %{conn: conn} do
    for marker <- [:hidden, :deleted] do
      tip = tip_fixture()
      video = attached_video_fixture(review_fixture(tip))
      put_marker!(tip, marker)

      assert_plays(conn, video)
    end
  end

  test "deleted, unplayable, expired, image and unknown rows answer 404", %{conn: conn} do
    author = user_fixture()
    moderator = moderator!(user_fixture())

    tip = tip_fixture(author)
    deleted = attached_video_fixture(tip)
    put_marker!(tip, :deleted)

    for viewer <- [author, moderator], do: assert_not_found(log_in_user(conn, viewer), deleted.id)

    author_conn = log_in_user(conn, author)
    expired_at = DateTime.add(DateTime.utc_now(:second), -50 * 3600)

    denied = [
      cleanup_media_fixture(tip_fixture(author)),
      staged_video_fixture(author),
      staged_video_fixture(author, %{state: :processing, stream_uid: "stream-processing"}),
      staged_video_fixture(author, %{state: :failed}),
      staged_ready_fixture(author, %{created_at: expired_at}),
      image_fixture(tip_fixture(author))
    ]

    for row <- denied, do: assert_not_found(author_conn, row.id)

    assert_not_found(author_conn, deleted.id + 1_000_000)
    assert_not_found(author_conn, "abc")
  end

  test "a revoked session loses staged and hidden videos but keeps public ones", %{conn: conn} do
    author = user_fixture()
    staged = staged_ready_fixture(author)
    hidden_tip = tip_fixture(author)
    hidden = attached_video_fixture(hidden_tip)
    put_marker!(hidden_tip, :hidden)
    public = attached_video_fixture(tip_fixture())

    conn = log_in_user(conn, author)
    assert_plays(conn, staged)

    {:ok, _family_ids} = Accounts.revoke_user_session_family(get_session(conn, :user_token))

    assert_not_found(conn, staged.id)
    assert_not_found(conn, hidden.id)
    assert_plays(conn, public)
  end

  describe "with unusable signing settings" do
    setup do
      original = Application.fetch_env!(:tips, StreamSigner)
      on_exit(fn -> Application.put_env(:tips, StreamSigner, original) end)
      %{settings: original[:settings]}
    end

    test "watch and thumbnail answer 500, never a redirect, and log the variable",
         %{conn: conn, settings: settings} do
      video = attached_video_fixture(tip_fixture())
      key = JSON.decode!(File.read!(@key_path))
      rsa_key = &%{settings | signing_key: &1 |> JSON.encode!() |> Base.encode64()}

      broken = [
        {"CLOUDFLARE_STREAM_SIGNING_KEY", %{settings | signing_key: " "}},
        {"CLOUDFLARE_STREAM_SIGNING_KEY", %{settings | signing_key: Base.encode64("{\"kty\"")}},
        # Decodes to an RSA private record that cannot sign.
        {"CLOUDFLARE_STREAM_SIGNING_KEY", rsa_key.(Map.delete(key, "n"))},
        # Has every member, but signing fails.
        {"CLOUDFLARE_STREAM_SIGNING_KEY", rsa_key.(%{key | "n" => "AA"})},
        {"CLOUDFLARE_STREAM_CUSTOMER_CODE", %{settings | customer_code: ""}}
      ]

      for {variable, broken_settings} <- broken, request <- [&watch/2, &thumbnail/2] do
        Application.put_env(:tips, StreamSigner, settings: broken_settings)

        {response, log} = with_log(fn -> request.(conn, video.id) end)

        assert response.status == 500
        assert get_resp_header(response, "location") == []

        assert log =~
                 "Media #{video.id}: signing unavailable: #{variable} is missing or malformed"

        refute log =~ video.stream_uid
        refute log =~ key["d"]
      end
    end
  end
end
