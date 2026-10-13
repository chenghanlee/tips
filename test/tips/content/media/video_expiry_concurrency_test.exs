defmodule Tips.Content.Media.VideoExpiryConcurrencyTest do
  # The expiry run and the opposing write run on their own backends and commit for
  # real. A release is simulated by a transaction that locks the row and stores the
  # uid, as `release/3` does; its own deadline guard refuses a due row.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.LockSessions
  import Tips.MediaFixtures

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content
  alias Tips.Content.Media
  alias Tips.Content.Media.{Asset, CloudflareStream}
  alias Tips.Content.{Review, Tip, Vote}
  alias Tips.Repo

  @hour 3600

  @attrs %{
    title: "Race the expiry",
    body: "The claim and the expiry lock the same row.",
    tag_id: "workflow",
    model_id: nil,
    model_other: nil,
    environment_id: nil,
    prompt: nil,
    output: nil
  }

  setup do
    {author, tip} =
      unboxed(fn ->
        author = user_fixture()
        {author, tip_fixture(author, @attrs)}
      end)

    # The expiry reads run in tasks, which must reach this test's stub.
    Req.Test.set_req_test_to_shared()

    on_exit(fn ->
      Req.Test.set_req_test_to_private()
      unboxed(fn -> delete_all(author.id) end)
    end)

    %{
      author: author,
      scope: Scope.for_user(author),
      tip: tip,
      supervisor: start_supervised!(Task.Supervisor)
    }
  end

  # A known-uid upload for the tip's edit, two hours old: past the ten-minute margin.
  defp reserved(data) do
    unboxed(fn ->
      staged_video_fixture(data.author, %{
        target: {:edit_tip, data.tip.id},
        stream_uid: "stream-#{Ecto.UUID.generate()}",
        created_at: DateTime.add(DateTime.utc_now(:second), -2 * @hour)
      })
    end)
  end

  defp pendingupload(conn) do
    result = %{"uid" => "ignored", "status" => %{"state" => "pendingupload"}}

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, JSON.encode!(%{"success" => true, "result" => result}))
  end

  defp claim(data, id) do
    fn -> Content.edit_tip(data.scope, data.tip.id, 1, @attrs, [{:staged_video, id}]) end
  end

  test "a claim committed during the expiry read wins and the expiry writes nothing", data do
    video = reserved(data)
    test = self()

    Req.Test.stub(CloudflareStream, fn conn ->
      send(test, {:reading, self()})

      receive do
        :reply -> pendingupload(conn)
      after
        3_000 -> flunk("the test did not release the provider response")
      end
    end)

    expiry = call(data.supervisor, fn -> Media.expire_due() end)
    assert_receive {:reading, provider}, 2_000

    # The editor's refresh sees the completion, then the edit claims the video.
    assert :applied =
             unboxed(fn -> Media.transition_video(video.id, video.stream_uid, {:ready, 10.0}) end)

    claimer = open(data.supervisor)
    assert {:ok, %{id: tip_id}} = run(claimer, claim(data, video.id))
    send(provider, :reply)
    await_blocked(expiry, claimer)
    commit(claimer)

    assert {:ok, %{retired: 0, deferred: 0, uncertain: 0}} = finish(expiry)

    unboxed(fn ->
      assert %Asset{tip_id: ^tip_id, position: 0, cleanup_at: nil, expires_at: nil} =
               Repo.get!(Asset, video.id)

      assert Repo.all(jobs(video.id)) == []
    end)
  end

  test "an expiry committed before the claim leaves the claim upload_failed", data do
    video = reserved(data)
    Req.Test.stub(CloudflareStream, &pendingupload/1)

    assert {:ok, %{retired: 1}} = finish(call(data.supervisor, fn -> Media.expire_due() end))

    claimer = open(data.supervisor)
    assert {:error, {:upload_failed, [id]}} = run(claimer, claim(data, video.id))
    assert id == video.id
    roll_back(claimer)

    unboxed(fn ->
      assert %Asset{tip_id: nil, cleanup_at: %DateTime{}} = Repo.get!(Asset, video.id)
      assert %Tip{edit_version: 1} = Repo.get!(Tip, data.tip.id)
      assert [_job] = Repo.all(jobs(video.id))
    end)
  end

  test "a uid released after the snapshot keeps the row for a Stream read next run", data do
    video =
      unboxed(fn ->
        staged_video_fixture(data.author, %{
          created_at: DateTime.add(DateTime.utc_now(:second), -2 * @hour)
        })
      end)

    uid = "stream-#{Ecto.UUID.generate()}"
    releaser = open(data.supervisor)

    run(releaser, fn ->
      Repo.all(from(a in Asset, where: a.id == ^video.id, lock: "FOR NO KEY UPDATE"))
      Repo.update_all(from(a in Asset, where: a.id == ^video.id), set: [stream_uid: uid])
    end)

    # The run's snapshot still sees a NULL uid; its retirement waits on the release.
    expiry = call(data.supervisor, fn -> Media.expire_due() end)
    await_blocked(expiry, releaser)
    commit(releaser)

    assert {:ok, %{retired: 0}} = finish(expiry)

    unboxed(fn ->
      assert %Asset{stream_uid: ^uid, cleanup_at: nil, expires_at: expires_at} =
               Repo.get!(Asset, video.id)

      assert expires_at == video.expires_at
    end)

    test = self()

    Req.Test.stub(CloudflareStream, fn conn ->
      send(test, {:read, conn.request_path})
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:ok, %{uncertain: 1}} = finish(call(data.supervisor, fn -> Media.expire_due() end))
    assert_received {:read, "/client/v4/accounts/synthetic-account/stream/" <> ^uid}
  end

  defp jobs(media_id) do
    from(j in Oban.Job,
      where: j.worker == "Tips.Workers.CleanupMedia" and j.args["media_id"] == ^media_id
    )
  end

  defp delete_all(user_id) do
    media_ids = Repo.all(from(a in Asset, where: a.user_id == ^user_id, select: a.id))
    tip_ids = Repo.all(from(t in Tip, where: t.user_id == ^user_id, select: t.id))
    review_ids = Repo.all(from(r in Review, where: r.tip_id in ^tip_ids, select: r.id))

    for id <- media_ids, do: Repo.delete_all(jobs(id))
    Repo.delete_all(from(a in Asset, where: a.user_id == ^user_id))
    Repo.delete_all(from(v in Vote, where: v.tip_id in ^tip_ids or v.review_id in ^review_ids))
    Repo.delete_all(from(s in "tip_search", where: s.tip_id in ^tip_ids))
    Repo.delete_all(from(r in Review, where: r.id in ^review_ids))
    Repo.delete_all(from(t in Tip, where: t.id in ^tip_ids))
    Repo.delete_all(from(u in User, where: u.id == ^user_id))
  end
end
