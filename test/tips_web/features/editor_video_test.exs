defmodule TipsWeb.EditorVideoTransferTest do
  @moduledoc """
  Real-browser tests of the video transfer (#85): tus-js-client sends the
  file to `Tips.TusStub` on the page's origin while the page reserves,
  refreshes and discards through the shared Stream stub. A reconnect keeps
  the transfer, a reload resumes it from the reselected file, and Remove
  aborts it. The page's preflight and cycle are in `TipsWeb.EditorVideoTest`.
  """
  # The Stream stub is shared with the page's processes.
  use Tips.FeatureCase, async: false

  import Tips.AccountsFixtures

  alias Tips.Content.Media.Asset
  alias Tips.{Repo, TusStub}

  @moduletag :browser
  @moduletag :tmp_dir

  setup %{session: session} do
    start_supervised!(TusStub)
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    user = user_fixture()
    sign_in(session, user)
    %{evidence: "#editor-#{user.id}-tip-evidence"}
  end

  defp video(dir, size) do
    path = Path.join(dir, "clip.mp4")
    File.write!(path, :binary.copy("v", size))
    path
  end

  defp select_video(session, path) do
    session
    |> visit("/editor/tips/new")
    |> assert_has(css(".phx-connected"))
    |> click(css("summary", text: "Prompt and result"))
    |> attach_file(file_field("Add a video (optional)"), path: path)

    assert_receive {:reserved, uid}, 5000
    uid
  end

  defp await_upload(uid, match?),
    do: await_found(fn -> if match?.(TusStub.upload(uid)), do: true end)

  defp deadline_hours(%Asset{expires_at: expires_at, created_at: created_at}),
    do: div(DateTime.diff(expires_at, created_at), 3600)

  feature "a reconnect mid-transfer keeps the one reservation, its deadline and the transfer",
          %{session: session, tmp_dir: dir, evidence: evidence} do
    TusStub.stub_stream(hold: 1500)
    uid = select_video(session, video(dir, 3000))
    await_upload(uid, &(&1.patches == 1))

    reconnect_live(session)
    assert_has(session, css("[data-phx-main].phx-connected"))

    assert [%Asset{stream_uid: ^uid, state: :uploading} = row] = Repo.all(Asset)
    assert deadline_hours(row) == 1
    assert %{offset: 0} = TusStub.upload(uid)

    # The held chunk lands after the reconnect; the cycle observes completion.
    assert_has(session, css("#{evidence}-video-#{row.id}", text: "Ready"))
    assert %Asset{stream_uid: ^uid, state: :ready} = row = Repo.reload!(row)
    assert deadline_hours(row) == 49
    assert_has(session, css("button[type=submit]:not([disabled])", text: "Publish"))
    refute_received {:reserved, _another}
  end

  feature "a reload resumes the same reservation from the reselected file",
          %{session: session, tmp_dir: dir, evidence: evidence} do
    TusStub.stub_stream(hold: 800, cap: 1000)
    path = video(dir, 3000)
    uid = select_video(session, path)

    # The draft keeps the video; the first chunk is stored and the second is held.
    await_found(fn -> if drafts(session) =~ ~s("staged_video"), do: true end)
    await_upload(uid, &(&1.answered == 1 and &1.patches == 2))
    [row] = Repo.all(Asset)

    session
    |> visit("/editor/tips/new")
    |> assert_has(css("summary", text: "Prompt and result · 1 attachment"))
    |> click(css("summary", text: "Prompt and result"))
    |> assert_has(
      css("#{evidence}-video-#{row.id}",
        text: "Upload interrupted. Select the same file to resume."
      )
    )
    |> assert_has(css("#{evidence}-video-#{row.id} button", text: "Resume"))

    # The cut chunk is answered on the server alone; the resume starts after it.
    await_upload(uid, &(&1.answered == 2))
    assert %{offset: offset} = TusStub.upload(uid)
    assert offset > 0

    # Resume opens this input; WebDriver sets its file instead of the picker. A chunk
    # sent from any offset but the stored one would be refused with 409.
    run_script(session, ~s|document.getElementById(args[0]).hidden = false|, [
      String.trim_leading("#{evidence}-video-input", "#")
    ])

    attach_file(session, file_field("Add a video (optional)"), path: path)
    await_upload(uid, &(&1.patches == 3))

    assert Map.take(Repo.reload!(row), [:state, :stream_uid, :expires_at, :upload_url]) ==
             Map.take(row, [:state, :stream_uid, :expires_at, :upload_url])

    assert_has(session, css("#{evidence}-video-#{row.id}", text: "Ready"))
    assert %Asset{state: :ready, stream_uid: ^uid} = ready = Repo.reload!(row)
    assert deadline_hours(ready) == 49
    assert %{offset: 3000, length: 3000} = TusStub.upload(uid)
    refute_received {:reserved, _another}
  end

  feature "Remove mid-transfer aborts it: no chunk follows, and the row is in cleanup",
          %{session: session, tmp_dir: dir, evidence: evidence} do
    TusStub.stub_stream(hold: 1000, cap: 1000)
    uid = select_video(session, video(dir, 2000))
    await_upload(uid, &(&1.patches == 1))
    [row] = Repo.all(Asset)

    session
    |> click(css("#{evidence}-video-#{row.id} button", text: "Remove"))
    |> assert_has(css("#{evidence}-video-input", visible: true))

    assert %Asset{cleanup_at: %DateTime{}} = Repo.reload!(row)

    # Unaborted, tus sends the next chunk as soon as the held one is answered.
    await_upload(uid, &(&1.answered == 1))
    Process.sleep(500)
    assert %{patches: 1, offset: 1000} = TusStub.upload(uid)
  end

  # Every stored draft record, as JSON.
  defp drafts(session) do
    run_script(session, """
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open("tips-editor-drafts")
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
    const request = db.transaction("drafts").objectStore("drafts").getAll()
    const records = await new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
    db.close()
    return JSON.stringify(records)
    """)
  end
end
