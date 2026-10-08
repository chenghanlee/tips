defmodule Tips.Content.Media.VideoStatusTest do
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures

  alias Tips.Accounts.Scope
  alias Tips.Content
  alias Tips.Content.Media.{Asset, CloudflareStream}

  @hour 3600

  setup do
    user = user_fixture()
    %{user: user, scope: Scope.for_user(user)}
  end

  # Answers each status read with `reply.(uid, conn)` and reports the uid to the test.
  defp stub_stream(reply) do
    test = self()

    Req.Test.stub(CloudflareStream, fn conn ->
      "/client/v4/accounts/synthetic-account/stream/" <> uid = conn.request_path
      send(test, {:read, conn.method, uid})
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
      "readyToStream" => Keyword.get(opts, :ready_to_stream, state == "ready"),
      "duration" => Keyword.get(opts, :duration, -1),
      "status" => %{"state" => state, "errorReasonCode" => Keyword.get(opts, :reason, "")}
    }

    body = JSON.encode!(%{"success" => true, "errors" => [], "result" => result})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, body)
  end

  defp uid, do: "uid#{System.unique_integer([:positive])}"

  # A known-uid upload reserved `age` seconds ago: past its upload deadline when older than an hour.
  defp reserved(user, attrs \\ %{}, age \\ 2 * @hour) do
    created_at = DateTime.add(DateTime.utc_now(:second), -age)
    staged_video_fixture(user, Map.merge(%{stream_uid: uid(), created_at: created_at}, attrs))
  end

  defp read_uids do
    receive do
      {:read, "GET", uid} -> [uid | read_uids()]
    after
      0 -> []
    end
  end

  defp deadline_hours(%Asset{expires_at: expires_at, created_at: created_at}),
    do: DateTime.diff(expires_at, created_at) / @hour

  describe "transitions" do
    test "the first state after pendingupload sets the recovery deadline, even past the upload deadline",
         data do
      cooldown = DateTime.utc_now(:second)

      cases = [
        {"pendingupload", [], :uploading, nil, 1},
        {"queued", [], :processing, nil, 49},
        {"downloading", [], :processing, nil, 49},
        {"inprogress", [], :processing, nil, 49},
        {"ready", [duration: 12.5], :ready, 12.5, 49},
        {"ready", [duration: 180], :ready, 180.0, 49},
        {"ready", [duration: 180.5], :failed, nil, 49},
        {"error", [reason: "ERR_DURATION_EXCEED_CONSTRAINT"], :failed, nil, 49}
      ]

      rows = for _case <- cases, do: reserved(data.user, %{reconcile_after: cooldown})

      replies =
        Map.new(Enum.zip(rows, cases), fn {row, {state, opts, _, _, _}} ->
          {row.stream_uid, {state, opts}}
        end)

      stub_stream(fn uid, conn ->
        {state, opts} = replies[uid]
        video(conn, state, opts)
      end)

      assert {:ok, statuses} = Content.get_video_uploads(data.scope, Enum.map(rows, & &1.id))

      for {row, {stream_state, _opts, state, duration, hours}} <- Enum.zip(rows, cases) do
        assert %Asset{state: ^state, duration_s: ^duration} = saved = Repo.reload!(row)
        assert deadline_hours(saved) == hours, "#{stream_state}: #{deadline_hours(saved)} h"
        # Definitive progress clears the expiry cooldown; pendingupload is not progress.
        assert saved.reconcile_after == nil == (state != :uploading)

        assert %{media_id: row.id, state: state, expires_at: saved.expires_at, refresh: :ok} in statuses
      end

      assert Enum.sort(read_uids()) == Enum.sort(Enum.map(rows, & &1.stream_uid))
    end

    test "a processing row becomes ready or failed and keeps its recovery deadline", data do
      cases = [
        {"inprogress", [], :processing},
        {"ready", [duration: 30], :ready},
        {"error", [], :failed}
      ]

      for {stream_state, opts, state} <- cases do
        row = reserved(data.user, %{state: :processing})
        stub_stream(fn _uid, conn -> video(conn, stream_state, opts) end)

        assert {:ok, [%{state: ^state}]} = Content.get_video_uploads(data.scope, [row.id])
        assert %Asset{state: ^state, expires_at: expires_at} = Repo.reload!(row)
        assert expires_at == row.expires_at
      end
    end

    test "ready, failed, attached, removed and unreleased rows make no provider request", data do
      tip = tip_fixture(data.user)
      ready = reserved(data.user, %{state: :ready, duration_s: 10.0})
      failed = reserved(data.user, %{state: :failed})
      unreleased = staged_video_fixture(data.user)
      attached = attached_video_fixture(tip)

      removed =
        data.user
        |> reserved(%{state: :processing})
        |> Ecto.Changeset.change(cleanup_at: DateTime.utc_now(:second))
        |> Repo.update!()

      rows = [ready, failed, unreleased, attached, removed]
      no_request()

      assert {:ok, statuses} = Content.get_video_uploads(data.scope, Enum.map(rows, & &1.id))

      assert statuses == [
               %{media_id: ready.id, state: :ready, expires_at: ready.expires_at, refresh: :ok},
               %{
                 media_id: failed.id,
                 state: :failed,
                 expires_at: failed.expires_at,
                 refresh: :ok
               },
               %{
                 media_id: unreleased.id,
                 state: :uploading,
                 expires_at: unreleased.expires_at,
                 refresh: :ok
               },
               %{media_id: attached.id, state: :ready, expires_at: nil, refresh: :ok},
               %{
                 media_id: removed.id,
                 state: :removed,
                 expires_at: removed.expires_at,
                 refresh: :ok
               }
             ]

      assert Enum.map(rows, &Repo.reload!/1) == rows
    end
  end

  describe "late and out-of-order results" do
    for {name, change, stream_state, opts} <- [
          {"a committed ready result", :ready, "inprogress", []},
          {"a committed failure", :failed, "ready", [duration: 20]},
          {"an attachment", :attach, "ready", [duration: 20]},
          {"cleanup", :cleanup, "queued", []}
        ] do
      test "a response read before #{name} commits does not change the row", data do
        tip = tip_fixture(data.user)
        row = reserved(data.user, %{reconcile_after: DateTime.utc_now(:second)})
        test = self()

        stub_stream(fn _uid, conn ->
          # Another writer commits while the provider read is in flight.
          send(test, {:changed, change(row, unquote(change), tip)})
          video(conn, unquote(stream_state), unquote(opts))
        end)

        assert {:ok, [%{media_id: id}]} = Content.get_video_uploads(data.scope, [row.id])
        assert_received {:changed, changed}
        assert Repo.get!(Asset, id) == changed
      end
    end
  end

  # Each change moves the row past what the late response could set.
  defp change(row, :ready, _tip), do: complete(row, state: :ready, duration_s: 10.0)
  defp change(row, :failed, _tip), do: complete(row, state: :failed)

  # Attachment clears the expiry and the cooldown; a late response must not restore either.
  defp change(row, :attach, tip) do
    complete(row,
      state: :ready,
      duration_s: 10.0,
      tip_id: tip.id,
      position: 0,
      expires_at: nil,
      reconcile_after: nil
    )
  end

  defp change(row, :cleanup, _tip) do
    row
    |> Ecto.Changeset.change(cleanup_at: DateTime.utc_now(:second), reconcile_after: nil)
    |> Repo.update!()
    |> Repo.reload!()
  end

  defp complete(row, changes) do
    changes = Keyword.put_new(changes, :expires_at, DateTime.add(row.created_at, 49 * @hour))

    row
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
    |> Repo.reload!()
  end

  describe "provider outages" do
    test "timeouts, errors and rate limits preserve committed facts", data do
      cooldown = DateTime.utc_now(:second)

      replies = %{
        "timeout" => &Req.Test.transport_error(&1, :timeout),
        "refused" => &Req.Test.transport_error(&1, :econnrefused),
        "server" => &Plug.Conn.send_resp(&1, 500, ""),
        "missing" => &Plug.Conn.send_resp(&1, 404, ""),
        "garbled" => &Plug.Conn.send_resp(&1, 200, "not json"),
        "unknown" => &video(&1, "mystery"),
        "limited" => &Plug.Conn.send_resp(&1, 429, "")
      }

      rows =
        for {uid, _reply} <- replies,
            do: reserved(data.user, %{stream_uid: uid, reconcile_after: cooldown})

      processing = reserved(data.user, %{state: :processing})
      ready = reserved(data.user, %{state: :ready, duration_s: 10.0})

      stub_stream(fn uid, conn ->
        reply = Map.get(replies, uid, &Req.Test.transport_error(&1, :timeout))
        reply.(conn)
      end)

      ids = Enum.map(rows ++ [processing, ready], & &1.id)
      assert {:ok, statuses} = Content.get_video_uploads(data.scope, ids)

      refreshes = Map.new(statuses, &{&1.media_id, &1.refresh})

      for row <- rows do
        expected = if row.stream_uid == "limited", do: :rate_limited, else: :uncertain
        assert refreshes[row.id] == expected, row.stream_uid
      end

      assert refreshes[processing.id] == :uncertain
      assert refreshes[ready.id] == :ok

      # Timeout is still checking: no failure, no deadline or cooldown change, no ready regression.
      assert Enum.map(rows ++ [processing, ready], &Repo.reload!/1) == rows ++ [processing, ready]
      refute ready.stream_uid in read_uids()
    end
  end

  describe "admission" do
    test "malformed, overlarge and duplicate id lists fail before any request", data do
      row = reserved(data.user)
      no_request()

      for ids <- [nil, "1", [0], [-1], ["x"], [row.id, row.id], Enum.to_list(1..11)] do
        assert {:error, %Ecto.Changeset{}} = Content.get_video_uploads(data.scope, ids),
               inspect(ids)
      end

      assert Content.get_video_uploads(data.scope, []) == {:ok, []}
    end

    test "an unowned, missing or non-video id fails the whole list before any request", data do
      mine = reserved(data.user)
      other = reserved(user_fixture())
      image = image_fixture(tip_fixture(data.user))
      no_request()

      for id <- [other.id, image.id, other.id + image.id + 1_000_000] do
        assert Content.get_video_uploads(data.scope, [mine.id, id]) == {:error, :not_found}
      end
    end

    test "the author and each target are re-admitted before any request", data do
      no_request()
      row = reserved(data.user)

      assert Content.get_video_uploads(nil, [row.id]) == {:error, :unauthenticated}

      unconfirmed = unconfirmed_user_fixture()
      theirs = reserved(unconfirmed)

      assert Content.get_video_uploads(Scope.for_user(unconfirmed), [theirs.id]) ==
               {:error, :unconfirmed}

      deleted = tip_fixture(data.user, %{deleted_at: DateTime.utc_now(:second)})
      dead = tip_fixture(user_fixture(), %{dead_at: DateTime.utc_now(:second)})

      for target <- [{:edit_tip, deleted.id}, {:new_review, dead.id, Ecto.UUID.generate()}] do
        stale = reserved(data.user, %{target: target})
        assert Content.get_video_uploads(data.scope, [row.id, stale.id]) == {:error, :not_found}
      end
    end
  end

  describe "bounded reads" do
    test "at most three status reads run at once", data do
      rows = for _ <- 1..7, do: reserved(data.user)
      test = self()

      Req.Test.stub(CloudflareStream, fn conn ->
        send(test, {:reading, self()})

        receive do
          :answer -> video(conn, "queued")
        after
          5_000 -> flunk("the test did not answer the read")
        end
      end)

      caller =
        Task.async(fn -> Content.get_video_uploads(data.scope, Enum.map(rows, & &1.id)) end)

      # Answer one read at a time; a fourth read never starts while three wait.
      Enum.reduce(0..6, [], fn answered, waiting ->
        [next | rest] = collect_reads(waiting, min(3, 7 - answered))
        send(next, :answer)
        rest
      end)

      assert {:ok, statuses} = Task.await(caller)
      assert Enum.all?(statuses, &(&1.state == :processing))
    end
  end

  # Waits until `count` reads are in flight, then checks that no further read starts.
  defp collect_reads(waiting, count) when length(waiting) >= count do
    refute_receive {:reading, _pid}, 50
    waiting
  end

  defp collect_reads(waiting, count) do
    assert_receive {:reading, pid}, 2_000
    collect_reads(waiting ++ [pid], count)
  end
end
