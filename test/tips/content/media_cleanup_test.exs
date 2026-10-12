defmodule Tips.Content.MediaCleanupTest do
  use Tips.DataCase, async: true
  use Oban.Testing, repo: Tips.Repo

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures

  alias Tips.Content.Media
  alias Tips.Content.Media.{CloudflareStream, R2}
  alias Tips.Workers.CleanupMedia

  # Answers every request to `provider` with `reply`, a status or `:timeout`, and reports it.
  defp stub(provider, reply) do
    test = self()

    Req.Test.stub(provider, fn conn ->
      send(test, {:request, conn.method, conn.request_path})

      case reply do
        :timeout -> Req.Test.transport_error(conn, :timeout)
        status -> Plug.Conn.send_resp(conn, status, "")
      end
    end)
  end

  defp stream_path(uid), do: "/client/v4/accounts/synthetic-account/stream/#{uid}"
  defp r2_path(key), do: "/tips-test/#{key}"

  defp image_in_cleanup,
    do: image_fixture(tip_fixture(user_fixture()), cleanup_at: now(), position: nil)

  defp now, do: DateTime.utc_now(:second)

  describe "retire/1" do
    test "deletes a video without a uid and enqueues nothing" do
      user = user_fixture()
      uploading = staged_video_fixture(user)
      failed = staged_video_fixture(user, state: :failed)

      assert :ok = Media.retire([uploading.id, failed.id])

      assert [nil, nil] == Enum.map([uploading, failed], &Repo.reload/1)
      refute_enqueued(worker: CleanupMedia)
    end

    test "leaves rows already in cleanup unchanged and enqueues nothing" do
      user = user_fixture()
      video = cleanup_media_fixture(tip_fixture(user))
      unreleased = staged_video_fixture(user, cleanup_at: now())

      assert :ok = Media.retire([video.id, unreleased.id])

      assert Enum.map([video, unreleased], &Repo.reload/1) == [video, unreleased]
      refute_enqueued(worker: CleanupMedia)
    end

    test "retiring a row twice enqueues one job" do
      image = image_fixture(tip_fixture(user_fixture()))

      assert :ok = Media.retire([image.id])
      assert :ok = Media.retire([image.id])

      assert [%{args: %{"media_id" => id}}] = all_enqueued(worker: CleanupMedia)
      assert id == image.id
    end

    test "a rolled-back transaction keeps the row and enqueues nothing" do
      image = image_fixture(tip_fixture(user_fixture()))

      assert {:error, :rolled_back} =
               Repo.transact(fn ->
                 :ok = Media.retire([image.id])
                 {:error, :rolled_back}
               end)

      assert Repo.reload(image) == image
      refute_enqueued(worker: CleanupMedia)
    end
  end

  describe "enqueue_cleanup/1" do
    test "re-creates a pruned job from the cleanup row, once" do
      image = image_in_cleanup()
      live = image_fixture(tip_fixture(user_fixture()))
      refute_enqueued(worker: CleanupMedia)

      assert :ok = Media.enqueue_cleanup([image.id, live.id])
      assert :ok = Media.enqueue_cleanup([image.id])

      assert [%{args: %{"media_id" => id}, queue: "media", max_attempts: 10}] =
               all_enqueued(worker: CleanupMedia)

      assert id == image.id
    end
  end

  describe "CleanupMedia" do
    test "deletes a video's Stream asset, then its row; a missing asset counts as deleted" do
      for status <- [200, 404] do
        video = cleanup_media_fixture(tip_fixture(user_fixture()))
        stub(CloudflareStream, status)

        assert :ok = perform_job(CleanupMedia, %{media_id: video.id})

        assert_received {:request, "DELETE", path}
        assert path == stream_path(video.stream_uid)
        assert Repo.reload(video) == nil
      end
    end

    test "a Stream timeout or server error keeps the video row for a later attempt" do
      video = cleanup_media_fixture(tip_fixture(user_fixture()))

      for reply <- [:timeout, 503] do
        stub(CloudflareStream, reply)
        assert {:error, _reason} = perform_job(CleanupMedia, %{media_id: video.id})
        assert Repo.reload(video) == video
      end

      stub(CloudflareStream, 200)
      assert :ok = perform_job(CleanupMedia, %{media_id: video.id})
      assert Repo.reload(video) == nil
    end

    test "deletes an image's R2 object, then its row; a missing object counts as deleted" do
      for status <- [204, 404] do
        image = image_in_cleanup()
        stub(R2, status)

        assert :ok = perform_job(CleanupMedia, %{media_id: image.id})

        assert_received {:request, "DELETE", path}
        assert path == r2_path(image.key)
        assert Repo.reload(image) == nil
      end
    end

    test "an R2 timeout or server error keeps the image row for a later attempt" do
      image = image_in_cleanup()

      for reply <- [:timeout, 500] do
        stub(R2, reply)
        assert {:error, _reason} = perform_job(CleanupMedia, %{media_id: image.id})
        assert Repo.reload(image) == image
      end

      stub(R2, 204)
      assert :ok = perform_job(CleanupMedia, %{media_id: image.id})
      assert Repo.reload(image) == nil
    end

    test "a row not in cleanup, or a missing one, is cancelled without a provider request" do
      image = image_fixture(tip_fixture(user_fixture()))

      assert {:cancel, _reason} = perform_job(CleanupMedia, %{media_id: image.id})
      assert {:cancel, _reason} = perform_job(CleanupMedia, %{media_id: image.id + 1_000_000})

      assert Repo.reload(image) == image
      refute_received {:request, _method, _path}
    end
  end
end
