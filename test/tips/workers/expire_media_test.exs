defmodule Tips.Workers.ExpireMediaTest do
  # Races with release and claims are in `Tips.Content.Media.VideoExpiryConcurrencyTest`.
  use Tips.DataCase, async: true
  use Oban.Testing, repo: Tips.Repo

  import Tips.AccountsFixtures
  import Tips.MediaFixtures

  alias Tips.Content.Media.{Asset, CloudflareStream}
  alias Tips.Workers.{CleanupMedia, ExpireMedia}

  @hour 3600

  setup do
    %{user: user_fixture()}
  end

  # Answers each status read with `reply.(uid, conn)` and reports the uid to the test.
  defp stub_stream(reply) do
    test = self()

    Req.Test.stub(CloudflareStream, fn conn ->
      "/client/v4/accounts/synthetic-account/stream/" <> uid = conn.request_path
      send(test, {:read, uid})
      reply.(uid, conn)
    end)
  end

  defp no_request do
    Req.Test.stub(CloudflareStream, fn conn ->
      flunk("unexpected #{conn.method} #{conn.request_path}")
    end)
  end

  defp video(conn, state, opts \\ []) do
    result = %{
      "uid" => "ignored",
      "readyToStream" => state == "ready",
      "duration" => Keyword.get(opts, :duration, -1),
      "status" => %{"state" => state}
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, JSON.encode!(%{"success" => true, "result" => result}))
  end

  defp uid, do: "uid#{System.unique_integer([:positive])}"

  # A known-uid upload reserved `age` seconds ago, still `uploading`.
  defp reserved(user, age) do
    created_at = DateTime.add(DateTime.utc_now(:second), -age)
    staged_video_fixture(user, %{stream_uid: uid(), created_at: created_at})
  end

  # A completed upload whose recovery deadline falls `offset` seconds after this statement.
  defp completed(user, state, offset) do
    duration_s = if state == :ready, do: 10.0
    row = staged_video_fixture(user, %{stream_uid: uid(), state: state, duration_s: duration_s})

    {1, _} =
      from(a in Asset,
        where: a.id == ^row.id,
        update: [
          set: [
            created_at:
              fragment(
                "statement_timestamp() - interval '49 hours' + ? * interval '1 second'",
                ^offset
              ),
            expires_at: fragment("statement_timestamp() + ? * interval '1 second'", ^offset)
          ]
        ]
      )
      |> Repo.update_all([])

    Repo.reload!(row)
  end

  defp read_uids do
    receive do
      {:read, uid} -> [uid | read_uids()]
    after
      0 -> []
    end
  end

  defp cleanup_ids do
    for %Oban.Job{args: %{"media_id" => id}} <- all_enqueued(worker: CleanupMedia), do: id
  end

  test "an uncertain read defers its row, so fifty per run let the rest progress", data do
    rows = for _ <- 1..51, do: reserved(data.user, 2 * @hour)
    {first, [last]} = Enum.split(rows, 50)
    stub_stream(fn _uid, conn -> Req.Test.transport_error(conn, :timeout) end)
    before_run = DateTime.utc_now(:second)

    assert {:ok, %{uncertain: 50, retired: 0, deferred: 0, transitioned: 0}} =
             perform_job(ExpireMedia, %{})

    assert Enum.sort(read_uids()) == Enum.sort(Enum.map(first, & &1.stream_uid))

    for row <- first do
      assert %Asset{state: :uploading, reconcile_after: %DateTime{} = cooldown} =
               saved = Repo.reload!(row)

      assert saved.expires_at == row.expires_at
      # Wall time after the attempt plus ten minutes.
      assert DateTime.diff(cooldown, before_run) in 600..610
    end

    assert Repo.reload!(last) == last

    assert {:ok, %{uncertain: 1}} = perform_job(ExpireMedia, %{})
    assert read_uids() == [last.stream_uid]
    assert %Asset{reconcile_after: %DateTime{}} = Repo.reload!(last)

    assert {:ok, %{uncertain: 0, retired: 0}} = perform_job(ExpireMedia, %{})
    assert read_uids() == []

    # The cooldown ends; a definitive read now retires the rows and clears it.
    ids = Enum.map(first, & &1.id)

    Repo.update_all(from(a in Asset, where: a.id in ^ids),
      set: [reconcile_after: DateTime.add(before_run, -1)]
    )

    stub_stream(fn _uid, conn -> video(conn, "pendingupload") end)

    assert {:ok, %{retired: 50}} = perform_job(ExpireMedia, %{})
    assert Enum.sort(read_uids()) == Enum.sort(Enum.map(first, & &1.stream_uid))

    for row <- first do
      assert %Asset{cleanup_at: %DateTime{}, reconcile_after: nil, expires_at: expires_at} =
               Repo.reload!(row)

      assert expires_at == row.expires_at
    end

    assert Enum.sort(cleanup_ids()) == Enum.sort(ids)
  end

  test "completed rows retire at the recovery deadline with one cleanup job each", data do
    states = [:processing, :ready, :failed]
    due = for state <- states, do: completed(data.user, state, 0)
    early = for state <- states, do: completed(data.user, state, 1)

    unreleased =
      staged_video_fixture(data.user, %{
        created_at: DateTime.add(DateTime.utc_now(:second), -@hour)
      })

    no_request()

    assert {:ok, %{retired: 4, transitioned: 0, deferred: 0, uncertain: 0}} =
             perform_job(ExpireMedia, %{})

    for row <- due do
      assert %Asset{cleanup_at: %DateTime{}, stream_uid: uid, state: state} = Repo.reload!(row)
      assert {uid, state} == {row.stream_uid, row.state}
    end

    assert Enum.map(early, &Repo.reload!/1) == early
    assert Repo.get(Asset, unreleased.id) == nil
    assert Enum.sort(cleanup_ids()) == Enum.sort(Enum.map(due, & &1.id))
  end

  test "pendingupload is definitive only from ten minutes after the upload deadline", data do
    inside = reserved(data.user, @hour + 9 * 60)
    at_margin = reserved(data.user, @hour + 10 * 60)
    completing = reserved(data.user, @hour + 9 * 60)

    stub_stream(fn uid, conn ->
      if uid == completing.stream_uid,
        do: video(conn, "ready", duration: 10),
        else: video(conn, "pendingupload")
    end)

    assert {:ok, %{deferred: 1, retired: 1, transitioned: 1, uncertain: 0}} =
             perform_job(ExpireMedia, %{})

    assert %Asset{state: :uploading, cleanup_at: nil, expires_at: expires_at} =
             saved = Repo.reload!(inside)

    assert expires_at == inside.expires_at
    assert saved.reconcile_after == DateTime.add(expires_at, 600)

    assert %Asset{cleanup_at: %DateTime{}, reconcile_after: nil} = Repo.reload!(at_margin)
    assert cleanup_ids() == [at_margin.id]

    assert %Asset{state: :ready, duration_s: 10.0, reconcile_after: nil} =
             ready = Repo.reload!(completing)

    assert ready.expires_at == DateTime.add(ready.created_at, 49 * @hour)
  end
end
