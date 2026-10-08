defmodule Tips.Content.Media.VideoUploadConcurrencyTest do
  # The reservation and the opposing write run on their own backends and commit for
  # real. The test observes the uid write waiting on the media-row lock before the
  # opposing transaction commits. Cleanup and expiry workers do not exist yet, so their
  # writes are database steps that lock the row first.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.LockSessions

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content
  alias Tips.Content.Media.{Asset, CloudflareStream}
  alias Tips.Repo

  setup do
    user = unboxed(fn -> user_fixture() end)
    # The reservation runs in a task process, which must reach this test's stub.
    Req.Test.set_req_test_to_shared()

    on_exit(fn ->
      Req.Test.set_req_test_to_private()

      unboxed(fn ->
        Repo.delete_all(from(a in Asset, where: a.user_id == ^user.id))
        Repo.delete_all(from(u in User, where: u.id == ^user.id))
      end)
    end)

    %{user: user, scope: Scope.for_user(user), supervisor: start_supervised!(Task.Supervisor)}
  end

  for change <- [:deadline, :cleanup] do
    test "a #{change} committed during the uid write's lock wait releases no URL", data do
      test = self()

      Req.Test.stub(CloudflareStream, fn conn ->
        send(test, {:reserving, self()})

        receive do
          :reply ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://upload.test/tus/late")
            |> Plug.Conn.put_resp_header("stream-media-id", "late")
            |> Plug.Conn.send_resp(201, "")
        after
          3_000 -> flunk("the test did not release the provider response")
        end
      end)

      caller =
        call(data.supervisor, fn ->
          Content.begin_video_upload(data.scope, {:new_tip, Ecto.UUID.generate()}, %{size: 1})
        end)

      assert_receive {:reserving, provider}, 2_000

      [id] =
        unboxed(fn ->
          Repo.all(from(a in Asset, select: a.id, where: a.user_id == ^data.user.id))
        end)

      locker = open(data.supervisor)
      run(locker, fn -> lock_and_change(id, unquote(change)) end)
      send(provider, :reply)
      await_blocked(caller, locker)
      # The deadline passes while the uid write still waits on the lock.
      if unquote(change) == :deadline, do: Process.sleep(500)
      commit(locker)

      assert finish(caller) == {:error, {:upload_failed, [id]}}
      assert %Asset{stream_uid: nil} = unboxed(fn -> Repo.get!(Asset, id) end)
    end
  end

  defp lock_and_change(id, change) do
    Repo.all(from(a in Asset, where: a.id == ^id, lock: "FOR NO KEY UPDATE"))
    query = from(a in Asset, where: a.id == ^id)

    case change do
      # The deadline falls 300 ms from now: after the uid write starts, before this commits.
      # One statement time keeps `media_deadline_chk`'s one-hour difference exact.
      :deadline ->
        query
        |> update(
          set: [
            created_at: fragment("statement_timestamp() - interval '1 hour' + interval '300 ms'"),
            expires_at: fragment("statement_timestamp() + interval '300 ms'")
          ]
        )
        |> Repo.update_all([])

      :cleanup ->
        Repo.update_all(query, set: [cleanup_at: DateTime.utc_now(:second)])
    end
  end
end
