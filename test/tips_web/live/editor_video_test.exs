defmodule TipsWeb.EditorVideoTest do
  @moduledoc """
  Acceptance evidence for #85 at the page: reserving and resuming a video
  from the editor's preflight, the status cycle's timing and guards, the
  slot states and Publish gating. The browser transfer is in
  `TipsWeb.EditorVideoTransferTest`; Media's guards are in
  `Tips.Content.Media.VideoResumeTest`.
  """
  # Not async: the reservation test raises the SQL log level for every process.
  use TipsWeb.ConnCase, async: false
  use Oban.Testing, repo: Tips.Repo

  import ExUnit.CaptureLog
  import Ecto.Query
  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures
  import Tips.MediaFixtures
  import Tips.VisibilityFixtures
  import TipsWeb.ReaderPageHelpers

  alias Tips.Accounts.UserToken
  alias Tips.Content.Media.{Asset, CloudflareStream}
  alias Tips.Repo
  alias Tips.Workers.CleanupMedia

  @size 4096

  setup :register_and_log_in_user

  setup %{user: user} do
    %{form: "#editor-#{user.id}-tip", evidence: "editor-#{user.id}-tip-evidence"}
  end

  # Reservations answer with a fresh uid. Status reads report their uid to the test and
  # answer with the next of `replies`, then `pendingupload`.
  defp stub_stream(replies \\ []) do
    test = self()
    {:ok, queue} = Agent.start_link(fn -> replies end)

    Req.Test.stub(CloudflareStream, fn
      %{method: "POST"} = conn ->
        uid = "uid#{System.unique_integer([:positive])}"
        send(test, {:reserved, uid})

        conn
        |> Plug.Conn.put_resp_header("location", "https://upload.test/tus/#{uid}?tusv2=true")
        |> Plug.Conn.put_resp_header("stream-media-id", uid)
        |> Plug.Conn.send_resp(201, "")

      %{method: "GET"} = conn ->
        "/client/v4/accounts/synthetic-account/stream/" <> uid = conn.request_path
        send(test, {:read, uid})
        reply(conn, Agent.get_and_update(queue, &next/1))
    end)
  end

  defp next([reply | rest]), do: {reply, rest}
  defp next([]), do: {"pendingupload", []}

  defp reply(conn, :uncertain), do: Req.Test.transport_error(conn, :timeout)
  defp reply(conn, :rate_limited), do: Plug.Conn.send_resp(conn, 429, "")

  defp reply(conn, state) do
    body = %{
      "result" => %{
        "status" => %{"state" => state},
        "readyToStream" => state == "ready",
        "duration" => 2
      }
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, JSON.encode!(body))
  end

  # A released reservation, as `begin_video_upload/3` leaves it.
  defp released(user, attrs \\ %{}) do
    uid = "uid#{System.unique_integer([:positive])}"

    staged_video_fixture(
      user,
      Map.merge(
        %{stream_uid: uid, upload_length: @size, upload_url: "https://upload.test/tus/#{uid}"},
        attrs
      )
    )
  end

  defp select_video(lv, form, size \\ @size) do
    lv
    |> file_input(form, :videos, [
      %{name: "clip.mp4", content: :binary.copy("x", size), type: "video/mp4"}
    ])
    |> preflight_upload()
  end

  # Applies the browser draft with `videos` selected, as the hook does after a reload.
  defp restore(lv, html, form, videos) do
    record =
      html
      |> record(form)
      |> put_in(
        ["intent", "uploads"],
        Enum.map(videos, &%{"tag" => "staged_video", "media_id" => &1})
      )

    render_hook(lv, "editor:restore", %{"identity" => identity(html, form), "record" => record})
    assert_reply(lv, %{status: "restored"})
  end

  defp slot(lv, evidence, id), do: text(render(lv), "##{evidence}-video-#{id}")
  defp wait(lv, user), do: text(render(lv), "#editor-#{user.id}-tip-wait")

  defp publish_disabled?(lv) do
    render(lv) |> find("button[type=submit]") |> LazyHTML.attribute("disabled") != []
  end

  # Re-renders until `fun` returns a truthy value, for up to 2 s.
  defp eventually(fun, tries \\ 40) do
    case fun.() do
      falsy when falsy in [nil, false] and tries > 1 ->
        Process.sleep(50)
        eventually(fun, tries - 1)

      result ->
        assert result
    end
  end

  test "selecting a video reserves it once, keeps its id in the draft and never shows the URL",
       %{conn: conn, user: user, form: form, evidence: evidence} do
    stub_stream()
    {:ok, lv, _html} = live(conn, ~p"/editor/tips/new")

    Logger.put_module_level(Ecto.Adapters.SQL, :debug)
    on_exit(fn -> Logger.delete_module_level(Ecto.Adapters.SQL) end)

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, %{entries: entries, errors: errors}} = select_video(lv, form)
        assert errors == %{}
        send(self(), {:entries, entries})
      end)

    Logger.delete_module_level(Ecto.Adapters.SQL)
    assert_received {:entries, entries}
    assert [%{uploader: "Tus", media_id: id, upload_url: url}] = Map.values(entries)
    assert_received {:reserved, uid}
    refute_received {:reserved, _another}

    assert %Asset{stream_uid: ^uid, upload_url: ^url, upload_length: @size, state: :uploading} =
             Repo.get!(Asset, id)

    assert url =~ uid
    # The cycle starts with the reservation.
    assert_receive {:read, ^uid}, 1000

    html = render(lv)

    assert %{"intent" => %{"uploads" => [%{"tag" => "staged_video", "media_id" => ^id}]}} =
             record(html, form)

    refute html =~ url
    assert log =~ ~s(INSERT INTO "media")
    refute log =~ url
    assert slot(lv, evidence, id) =~ "Video"
    assert wait(lv, user) == "Waiting for your video to be ready"
  end

  test "the interrupted slot resumes the same reservation with the same file only",
       %{conn: conn, user: user, form: form, evidence: evidence} do
    stub_stream()
    row = released(user)
    {:ok, lv, html} = live(conn, ~p"/editor/tips/new")
    restore(lv, html, form, [row.id])
    uid = row.stream_uid
    assert_receive {:read, ^uid}, 1000

    eventually(fn -> slot(lv, evidence, row.id) =~ "Upload interrupted. Select the same file" end)

    assert render(lv) |> find("##{evidence}-video-#{row.id} [data-video-resume]") |> Enum.count() ==
             1

    # Another file: an error at the slot, and nothing changes.
    assert {:ok, %{entries: entries, errors: errors}} = select_video(lv, form, @size - 1)
    assert entries == %{}
    assert [[%{reason: reason}]] = Map.values(errors)
    assert reason == "clip.mp4 isn't the same file as the interrupted upload."
    assert slot(lv, evidence, row.id) =~ reason

    assert {:ok, %{entries: entries}} = select_video(lv, form)
    assert [%{media_id: id, upload_url: url}] = Map.values(entries)
    assert {id, url} == {row.id, row.upload_url}
    refute_received {:reserved, _uid}
    assert Repo.reload!(row) == row
    assert [{:staged_video, ^id}] = uploads(render(lv), form)

    # A revoked session gets no capability, even before any broadcast reaches the page.
    Repo.delete_all(from(t in UserToken, where: t.user_id == ^user.id))
    assert {:ok, %{entries: %{}, errors: errors}} = select_video(lv, form)
    assert [[%{reason: "Your sign-in has expired" <> _}]] = Map.values(errors)
    refute_received {:reserved, _uid}
  end

  test "a ban, lost confirmation or revoked session stops the cycle and keeps the input",
       %{form: form} do
    for revoke <- [&full_ban!/1, &unconfirm/1, &revoke_sessions/1] do
      user = user_fixture()
      conn = log_in_user(build_conn(), user)
      form = String.replace(form, ~r/\d+/, "#{user.id}", global: false)
      stub_stream()
      row = released(user)
      uid = row.stream_uid

      {:ok, lv, html} = live(conn, ~p"/editor/tips/new")
      restore(lv, html, form, [row.id])
      render_change(lv, "change", %{"tip" => %{"title" => "Kept title"}})
      assert_receive {:read, ^uid}, 1000

      revoke.(user)
      eventually(fn -> render(lv) =~ "#{String.trim_leading(form, "#")}-refusal" end)

      html = render(lv)
      assert value(html, "tip[title]") == "Kept title"
      assert [{:staged_video, _id}] = uploads(html, form)
      # Drain a read that started before the change.
      receive do
        {:read, ^uid} -> :ok
      after
        0 -> :ok
      end

      refute_receive {:read, ^uid}, 400
    end
  end

  test "uncertain and rate-limited reads say still checking and double the delay; ready stops",
       %{conn: conn, user: user, form: form, evidence: evidence} do
    stub_stream([:uncertain, :rate_limited, "ready"])
    row = released(user)
    uid = row.stream_uid
    {:ok, lv, html} = live(conn, ~p"/editor/tips/new")

    log =
      capture_log(fn ->
        restore(lv, html, form, [row.id])
        assert_receive {:read, ^uid}, 1000
        eventually(fn -> slot(lv, evidence, row.id) =~ "Still checking" end)
        assert_receive {:read, ^uid}, 1000
        assert_receive {:read, ^uid}, 1000
        eventually(fn -> slot(lv, evidence, row.id) =~ "Ready" end)
      end)

    assert log =~ ~r/media=\[#{row.id}\] reason=:uncertain next_ms=100/
    assert log =~ ~r/media=\[#{row.id}\] reason=:rate_limited next_ms=200/
    refute slot(lv, evidence, row.id) =~ "Still checking"
    assert %Asset{state: :ready} = Repo.reload!(row)
    refute_receive {:read, ^uid}, 400
  end

  test "a stale cycle message is ignored and a closed page reads no more",
       %{conn: conn, user: user, form: form} do
    stub_stream()
    row = released(user)
    uid = row.stream_uid
    {:ok, lv, html} = live(conn, ~p"/editor/tips/new")
    restore(lv, html, form, [row.id])
    assert_receive {:read, ^uid}, 1000
    assert_receive {:read, ^uid}, 1000

    # The restore started generation 1; nothing scheduled the generations before it.
    send(lv.pid, {:refresh_videos, 0})
    render(lv)

    ref = Process.monitor(lv.pid)
    GenServer.stop(lv.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    receive do
      {:read, ^uid} -> :ok
    after
      0 -> :ok
    end

    refute_receive {:read, ^uid}, 400
  end

  test "Publish waits for the video, then publishes it; a stale click is refused",
       %{conn: conn, user: user, form: form} do
    stub_stream(["pendingupload", "ready"])
    row = released(user)
    {:ok, lv, html} = live(conn, ~p"/editor/tips/new")
    key = record(html, form)["submission_key"]
    Repo.update!(Ecto.Changeset.change(row, target: {:new_tip, key}))
    restore(lv, html, form, [row.id])

    eventually(fn -> wait(lv, user) == "Waiting for your video to be ready" end)
    assert publish_disabled?(lv)

    attrs = %{"title" => "Clip tip", "body" => "Steps.", "tag_id" => "other"}
    render_submit(lv, "submit", %{"tip" => attrs})
    assert text(render(lv), "#editor-#{user.id}-tip-refusal") =~ "An attachment isn't ready"

    eventually(fn -> not publish_disabled?(lv) end)
    assert render(lv) |> find("#editor-#{user.id}-tip-wait") |> Enum.count() == 0

    render_submit(lv, "submit", %{"tip" => attrs})
    assert_push_event(lv, "editor:clear", %{})
    assert %Asset{tip_id: tip_id, expires_at: nil} = Repo.reload!(row)
    assert is_integer(tip_id)
  end

  test "failed and expired videos keep their place with Replace and Remove and hold Publish",
       %{conn: conn, user: user, form: form, evidence: evidence} do
    stub_stream()
    failed = staged_video_fixture(user, %{state: :failed})
    past = DateTime.add(DateTime.utc_now(:second), -50 * 3600)

    expired =
      staged_video_fixture(user, %{
        state: :ready,
        stream_uid: "uid#{System.unique_integer([:positive])}",
        duration_s: 2.0,
        created_at: past
      })

    {:ok, lv, html} = live(conn, ~p"/editor/tips/new")
    restore(lv, html, form, [failed.id, expired.id])

    eventually(fn -> slot(lv, evidence, expired.id) =~ "This upload expired." end)

    assert slot(lv, evidence, failed.id) =~
             "Couldn't be processed. Videos must be under 3 minutes."

    for id <- [failed.id, expired.id] do
      assert slot(lv, evidence, id) =~ "Replace"
      assert slot(lv, evidence, id) =~ "Remove"
    end

    assert wait(lv, user) == "This video expired. Replace or remove it."
    assert publish_disabled?(lv)

    lv
    |> element("##{evidence}-video-#{expired.id} button", "Remove")
    |> render_click()

    expired_id = expired.id
    assert_push_event(lv, "editor:abort_video", %{media_id: ^expired_id})
    assert %Asset{cleanup_at: %DateTime{}} = Repo.reload!(expired)
    assert_enqueued(worker: CleanupMedia, args: %{media_id: expired.id})
    assert [{:staged_video, failed_id}] = uploads(render(lv), form)
    assert failed_id == failed.id
    refute publish_disabled?(lv)
  end

  defp unconfirm(user),
    do: Repo.update!(Ecto.Changeset.change(user, confirmed_at: nil))

  defp revoke_sessions(user),
    do: Repo.delete_all(from(t in UserToken, where: t.user_id == ^user.id))

  defp uploads(html, form) do
    for %{"tag" => "staged_video", "media_id" => id} <- record(html, form)["intent"]["uploads"],
        do: {:staged_video, id}
  end

  defp record(html, form), do: html |> data(form, "data-editor-record") |> JSON.decode!()
  defp identity(html, form), do: html |> data(form, "data-editor-identity") |> JSON.decode!()
  defp data(html, selector, name), do: html |> find(selector) |> LazyHTML.attribute(name) |> hd()

  defp value(html, name),
    do: html |> find(~s(input[name="#{name}"])) |> LazyHTML.attribute("value") |> hd()
end
