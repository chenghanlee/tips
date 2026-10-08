defmodule Tips.Content.Media.VideoUploadRealTest do
  # Real Stream reservations, with every transaction committed outside the SQL sandbox.
  # A forwarding plug sends the reservation to Stream unchanged, except where a case
  # rewrites the expiry, and decides when and whether the response reaches Tips. Each
  # observation of the row runs on its own connection, so it sees only committed state.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.LockSessions, only: [unboxed: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.Media
  alias Tips.Content.Media.{Asset, CloudflareStream}
  alias Tips.Repo

  @moduletag :real_provider
  @real [plug: nil, settings: nil]
  @size 12_345_678

  setup do
    user = unboxed(fn -> user_fixture() end)
    client = CloudflareStream.client!(@real)
    # Not linked: it outlives the test process for the cleanup below.
    {:ok, log} = Agent.start(fn -> [] end)

    on_exit(fn ->
      # Every reservation Stream created, whether or not Tips stored its uid.
      for uid <- Agent.get(log, & &1) do
        assert {:ok, %{status: 200}} = Req.delete(client, url: "/#{uid}")
        assert {:ok, %{status: 404}} = Req.get(client, url: "/#{uid}")
      end

      unboxed(fn ->
        Repo.delete_all(from(a in Asset, where: a.user_id == ^user.id))
        Repo.delete_all(from(u in User, where: u.id == ^user.id))
      end)

      Agent.stop(log)
    end)

    %{scope: Scope.for_user(user), client: client, log: log}
  end

  # Runs the operation as a top-level caller: its transactions commit for real. The
  # deadline case holds the connection past the default 120-second ownership timeout.
  defp begin(scope, size, plug) do
    :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: 300_000)

    try do
      Media.begin_video_upload(scope, {:new_tip, Ecto.UUID.generate()}, %{size: size},
        plug: plug,
        settings: nil
      )
    after
      Sandbox.checkin(Repo)
    end
  end

  defp refresh(scope, ids) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      Media.get_video_uploads(scope, ids, plug: nil, settings: nil)
    after
      Sandbox.checkin(Repo)
    end
  end

  # Refreshes every 3 seconds until `done?` holds, for at most 90 seconds.
  defp refresh_until(scope, id, done?, attempts \\ 30) do
    assert {:ok, [status]} = refresh(scope, [id])

    cond do
      done?.(status) ->
        status

      attempts > 1 ->
        Process.sleep(3_000)
        refresh_until(scope, id, done?, attempts - 1)

      true ->
        flunk("upload #{id} stayed #{inspect(status)}")
    end
  end

  # Reads committed state from a connection the operation does not use.
  defp committed(id), do: Task.await(Task.async(fn -> unboxed(fn -> Repo.get(Asset, id) end) end))

  defp commit_change(id, set) do
    Task.await(
      Task.async(fn ->
        unboxed(fn -> Repo.update_all(from(a in Asset, where: a.id == ^id), set: set) end)
      end)
    )
  end

  # The reservation as Tips sent it, the media id from its name, and Stream's response.
  # `before_send.(id, metadata)` runs first and returns the metadata to send. Every uid
  # Stream returns goes to `log`.
  defp forward(conn, log, before_send \\ fn _id, metadata -> metadata end) do
    {"upload-metadata", encoded} = List.keyfind(conn.req_headers, "upload-metadata", 0)
    metadata = decode(encoded)
    "tips-media-" <> id = metadata["name"]
    id = String.to_integer(id)
    metadata = before_send.(id, metadata)

    headers =
      for {name, value} <- conn.req_headers,
          name in ~w(authorization tus-resumable upload-length),
          do: {name, value}

    {:ok, response} =
      Req.post("#{conn.scheme}://#{conn.host}#{conn.request_path}?#{conn.query_string}",
        headers: [{"upload-metadata", encode(metadata)} | headers],
        retry: false,
        redirect: false,
        decode_body: false
      )

    case Req.Response.get_header(response, "stream-media-id") do
      [uid] -> Agent.update(log, &[uid | &1])
      [] -> :ok
    end

    {id, metadata, response}
  end

  defp reply(conn, response) do
    conn =
      for name <- ~w(location stream-media-id),
          value <- Req.Response.get_header(response, name),
          reduce: conn,
          do: (conn -> Plug.Conn.put_resp_header(conn, name, value))

    Plug.Conn.send_resp(conn, response.status, response.body)
  end

  defp decode(encoded) do
    Map.new(String.split(encoded, ","), fn pair ->
      case String.split(pair, " ") do
        [key] -> {key, nil}
        [key, value] -> {key, Base.decode64!(value)}
      end
    end)
  end

  defp encode(metadata) do
    Enum.map_join(~w(maxDurationSeconds requiresignedurls expiry name), ",", fn
      "requiresignedurls" -> "requiresignedurls"
      key -> key <> " " <> Base.encode64(metadata[key])
    end)
  end

  defp video(client, uid) do
    assert {:ok, %{status: 200, body: body}} = Req.get(client, url: "/#{uid}")
    JSON.decode!(body)["result"]
  end

  test "the uid is committed before the URL is released, and the URL alone authorizes tus",
       data do
    test = self()

    plug = fn conn ->
      {id, _metadata, response} =
        forward(conn, data.log, fn id, metadata ->
          send(test, {:before_call, committed(id)})
          metadata
        end)

      send(test, {:reserved, id, Req.Response.get_header(response, "stream-media-id")})
      reply(conn, response)
    end

    assert {:ok, %{media_id: id, upload_url: url, expires_at: expires_at}} =
             begin(data.scope, @size, plug)

    assert_received {:before_call, %Asset{id: ^id, state: :uploading, stream_uid: nil}}
    assert_received {:reserved, ^id, [uid]}

    # Committed, as another connection sees it, before the first request to the URL.
    assert %Asset{stream_uid: ^uid, state: :uploading, expires_at: ^expires_at} = committed(id)

    assert {:ok, %{status: 200} = head} =
             Req.head(url, headers: [tus_resumable: "1.0.0"], retry: false)

    assert Req.Response.get_header(head, "upload-offset") == ["0"]
    assert Req.Response.get_header(head, "upload-length") == [Integer.to_string(@size)]

    assert %{
             "requireSignedURLs" => true,
             "maxDurationSeconds" => 180,
             "meta" => %{"name" => name},
             "status" => %{"state" => "pendingupload"},
             "uploadExpiry" => upload_expiry
           } = video(data.client, uid)

    assert name == "tips-media-#{id}"
    assert {:ok, ^expires_at, 0} = DateTime.from_iso8601(upload_expiry)
  end

  test "a lost response releases no URL though Stream holds the reservation", data do
    test = self()

    plug = fn conn ->
      {id, _metadata, response} = forward(conn, data.log)
      send(test, {:reserved, id, Req.Response.get_header(response, "stream-media-id")})
      Req.Test.transport_error(conn, :timeout)
    end

    assert {:error, {:upload_failed, [id]}} = begin(data.scope, @size, plug)
    assert_received {:reserved, ^id, [uid]}
    assert %Asset{state: :uploading, stream_uid: nil, cleanup_at: nil} = committed(id)
    assert %{"status" => %{"state" => "pendingupload"}} = video(data.client, uid)
  end

  test "a response after a committed cleanup neither stores the uid nor revives the row",
       data do
    plug = fn conn ->
      {id, _metadata, response} = forward(conn, data.log)
      assert {1, _} = commit_change(id, cleanup_at: DateTime.utc_now(:second))
      reply(conn, response)
    end

    assert {:error, {:upload_failed, [id]}} = begin(data.scope, @size, plug)
    assert %Asset{state: :uploading, stream_uid: nil, cleanup_at: %DateTime{}} = committed(id)
  end

  # Stream refuses an expiry under two minutes ahead, so this case moves the row's
  # deadline and the reservation expiry together to 125 seconds ahead, then holds
  # Stream's response until both have passed.
  @tag timeout: 240_000
  test "a response after the shared deadline releases no URL, and Stream refuses the transfer",
       data do
    test = self()
    deadline = DateTime.add(DateTime.utc_now(:second), 125)

    plug = fn conn ->
      {id, metadata, response} =
        forward(conn, data.log, fn id, metadata ->
          created_at = DateTime.add(deadline, -3600)
          assert {1, _} = commit_change(id, created_at: created_at, expires_at: deadline)
          %{metadata | "expiry" => DateTime.to_iso8601(deadline)}
        end)

      Process.sleep(max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0) + 1_000)
      send(test, {:reserved, id, metadata, response})
      reply(conn, response)
    end

    assert {:error, {:upload_failed, [id]}} = begin(data.scope, 1, plug)
    assert_received {:reserved, ^id, %{"expiry" => expiry}, response}
    assert expiry == DateTime.to_iso8601(deadline)
    assert [uid] = Req.Response.get_header(response, "stream-media-id")
    assert [url] = Req.Response.get_header(response, "location")
    assert %Asset{state: :uploading, stream_uid: nil, expires_at: ^deadline} = committed(id)

    # The URL Tips withheld no longer accepts bytes either.
    assert {:ok, %{status: 400, body: body}} =
             Req.patch(url,
               headers: [
                 tus_resumable: "1.0.0",
                 upload_offset: "0",
                 content_type: "application/offset+octet-stream"
               ],
               body: "x",
               retry: false,
               decode_body: false
             )

    assert body =~ "10017"
    assert %{"status" => %{"state" => "pendingupload"}} = video(data.client, uid)
  end

  test "status reads keep a pending upload, then move the finished one to ready", data do
    file = File.read!(Path.expand("../../../fixtures/videos/two_seconds.mp4", __DIR__))

    plug = fn conn ->
      {_id, _metadata, response} = forward(conn, data.log)
      reply(conn, response)
    end

    assert {:ok, %{media_id: id, upload_url: url}} = begin(data.scope, byte_size(file), plug)

    # Stream reports `pendingupload`: a definite answer that changes nothing.
    assert {:ok, [%{state: :uploading, refresh: :ok}]} = refresh(data.scope, [id])
    assert %Asset{state: :uploading, created_at: created_at} = committed(id)

    assert {:ok, %{status: 204}} =
             Req.patch(url,
               body: file,
               headers: [
                 tus_resumable: "1.0.0",
                 upload_offset: "0",
                 content_type: "application/offset+octet-stream"
               ],
               retry: false
             )

    status = refresh_until(data.scope, id, &(&1.state not in [:uploading, :processing]))

    assert %{state: :ready, refresh: :ok, expires_at: expires_at} = status
    assert DateTime.diff(expires_at, created_at) == 49 * 3600
    assert %Asset{state: :ready, duration_s: duration, reconcile_after: nil} = committed(id)
    assert duration > 0 and duration <= 180
  end

  test "a rejected reservation fails the row with no uid", data do
    # An expiry under two minutes ahead: Stream refuses it with code 10005.
    soon = DateTime.utc_now(:second) |> DateTime.add(30) |> DateTime.to_iso8601()

    plug = fn conn ->
      {_id, _metadata, response} =
        forward(conn, data.log, fn _id, metadata -> %{metadata | "expiry" => soon} end)

      assert response.status == 400
      assert response.body =~ "10005"
      reply(conn, response)
    end

    assert {:error, {:upload_failed, [id]}} = begin(data.scope, @size, plug)
    assert %Asset{state: :failed, stream_uid: nil} = committed(id)
  end
end
