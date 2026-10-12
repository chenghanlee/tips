defmodule Tips.Content.Media.CleanupRealTest do
  # Real Stream and R2 deletion through the cleanup job. The job builds its clients from
  # the application environment, so this synchronous module replaces the test stubs
  # there. A forwarding plug sends each Stream request on unchanged and reports the
  # status Stream answers for a reservation without bytes.
  use Tips.DataCase, async: false
  use Oban.Testing, repo: Tips.Repo

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures

  alias Tips.Content.Media
  alias Tips.Content.Media.{CloudflareStream, R2}
  alias Tips.Workers.CleanupMedia

  @moduletag :real_provider
  @real [plug: nil, settings: nil]
  @fixture Path.expand("../../../fixtures/images/static.png", __DIR__)

  setup do
    stream = CloudflareStream.client!(@real)
    r2 = R2.client!(@real)
    expiry = DateTime.utc_now(:second) |> DateTime.add(600)

    # Each object's cleanup is registered before the next fallible call and runs on its
    # own, so one failure leaves nothing behind. Both deletes are repeat-safe.
    {:ok, %{uid: uid}} = CloudflareStream.reserve(stream, 1_000, expiry, "tips-test-67")
    on_exit(fn -> :ok = CloudflareStream.delete(stream, uid) end)

    # The stored key shape `media_key_chk` requires.
    key = "media/#{Ecto.UUID.generate()}.png"
    # Registered before the put, whose outcome can be unknown.
    on_exit(fn -> :ok = R2.delete(r2, key) end)
    :ok = R2.put(r2, key, File.read!(@fixture), "image/png")

    envs = for module <- [CloudflareStream, R2], do: {module, Application.get_env(:tips, module)}
    on_exit(fn -> for {module, env} <- envs, do: Application.put_env(:tips, module, env) end)
    test = self()
    Application.put_env(:tips, CloudflareStream, plug: &forward(&1, test))
    Application.put_env(:tips, R2, [])

    %{stream: stream, r2: r2, uid: uid, key: key}
  end

  defp forward(conn, test) do
    headers = for {"authorization", _value} = header <- conn.req_headers, do: header

    {:ok, response} =
      Req.request(
        method: conn.method,
        url: "https://#{conn.host}#{conn.request_path}",
        headers: headers,
        retry: false,
        redirect: false,
        decode_body: false
      )

    send(test, {:stream, conn.method, response.status})
    Plug.Conn.send_resp(conn, response.status, response.body)
  end

  test "a retired video and image are deleted at Stream and R2, then their rows", data do
    user = user_fixture()
    video = staged_video_fixture(user, stream_uid: data.uid)
    image = image_fixture(tip_fixture(user), key: data.key)

    assert :ok = Media.retire([video.id, image.id])

    for row <- [video, image] do
      assert :ok = perform_job(CleanupMedia, %{media_id: row.id})
      assert Repo.reload(row) == nil
    end

    # The reservation never received bytes: Stream still deletes it.
    assert_received {:stream, "DELETE", 200}

    assert {:ok, %{status: 404}} = Req.get(data.stream, url: "/" <> data.uid)
    assert {:ok, %{status: 404}} = Req.get(data.r2, url: "/" <> data.key)
  end
end
