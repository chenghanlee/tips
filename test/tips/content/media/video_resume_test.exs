defmodule Tips.Content.Media.VideoResumeTest do
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures
  import Tips.VisibilityFixtures

  alias Tips.Accounts.Scope
  alias Tips.Content
  alias Tips.Content.Media
  alias Tips.Content.Media.{Asset, CloudflareStream}

  @size 12_345_678

  setup do
    user = user_fixture()
    %{user: user, scope: Scope.for_user(user)}
  end

  defp stub_reservations do
    Req.Test.stub(CloudflareStream, fn conn ->
      uid = "uid#{System.unique_integer([:positive])}"

      conn
      |> Plug.Conn.put_resp_header("location", "https://upload.test/tus/#{uid}?tusv2=true")
      |> Plug.Conn.put_resp_header("stream-media-id", uid)
      |> Plug.Conn.send_resp(201, "")
    end)
  end

  defp no_request do
    Req.Test.stub(CloudflareStream, fn conn ->
      flunk("unexpected #{conn.method} #{conn.request_path}")
    end)
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

  test "resuming returns the stored endpoint of the same reservation and writes nothing", data do
    stub_reservations()
    key = Ecto.UUID.generate()

    assert {:ok, upload} = Content.begin_video_upload(data.scope, {:new_tip, key}, %{size: @size})
    row = Repo.get!(Asset, upload.media_id)
    no_request()

    assert Content.resume_video_upload(data.scope, upload.media_id, %{size: @size}) ==
             {:ok, upload}

    # Another file of another length is not the interrupted upload.
    assert Content.resume_video_upload(data.scope, upload.media_id, %{size: @size - 1}) ==
             {:error, :not_found}

    assert Repo.reload!(row) == row
    assert Repo.aggregate(Asset, :count) == 1
  end

  test "only the author's unfinished, unexpired, released upload with a valid target resumes",
       data do
    tip = tip_fixture()
    review = review_fixture(tip, %{user_id: data.user.id})
    parent = tip_fixture()
    past = DateTime.add(DateTime.utc_now(:second), -2 * 3600)

    rows = [
      released(user_fixture()),
      released(data.user, %{created_at: past}),
      staged_video_fixture(data.user, %{stream_uid: "uid-only", upload_length: @size}),
      processing(data.user),
      released(data.user, %{target: {:new_review, parent.id, Ecto.UUID.generate()}}),
      released(data.user, %{target: {:edit_review, review.id}}),
      cleanup(released(data.user))
    ]

    # The target of the last two stops being valid after the reservation.
    Repo.update!(Ecto.Changeset.change(parent, deleted_at: DateTime.utc_now(:second)))
    Repo.update!(Ecto.Changeset.change(review, deleted_at: DateTime.utc_now(:second)))
    no_request()

    for row <- rows do
      assert Content.resume_video_upload(data.scope, row.id, %{size: @size}) ==
               {:error, :not_found},
             inspect(row)
    end

    assert Content.resume_video_upload(data.scope, 9_000_000_000, %{size: @size}) ==
             {:error, :not_found}
  end

  test "resuming checks the caller and its input before any row", data do
    row = released(data.user)
    no_request()

    assert Content.resume_video_upload(nil, row.id, %{size: @size}) == {:error, :unauthenticated}

    for {id, attrs, errors} <- [
          {"x", %{size: @size}, %{media_id: ["is invalid"]}},
          {row.id, %{size: 0}, %{size: ["must be greater than 0"]}},
          {row.id, %{}, %{size: ["can't be blank"]}}
        ] do
      assert {:error, changeset} = Content.resume_video_upload(data.scope, id, attrs)
      assert errors_on(changeset) == errors
    end

    unconfirmed = unconfirmed_user_fixture()
    banned = full_ban!(user_fixture())

    for {user, reason} <- [{unconfirmed, :unconfirmed}, {banned, :forbidden}] do
      own = released(user)

      assert Content.resume_video_upload(Scope.for_user(user), own.id, %{size: @size}) ==
               {:error, reason}
    end

    # A resume spends the upload budget, as a reservation does.
    for _attempt <- 1..20, do: Content.resume_video_upload(data.scope, row.id, %{size: @size})

    assert {:error, {:rate_limited, _seconds}} =
             Content.resume_video_upload(data.scope, row.id, %{size: @size})
  end

  test "the endpoint is cleared when the upload completes and when it enters cleanup", data do
    completed = released(data.user)
    assert Media.transition_video(completed.id, completed.stream_uid, :processing) == :applied
    assert %Asset{state: :processing, upload_url: nil} = Repo.reload!(completed)

    retired = released(data.user)
    {:ok, :ok} = Repo.transact(fn -> {:ok, Media.retire([retired.id])} end)
    assert %Asset{cleanup_at: %DateTime{}, upload_url: nil} = Repo.reload!(retired)
  end

  defp processing(user) do
    staged_video_fixture(user, %{
      state: :processing,
      stream_uid: "uid#{System.unique_integer([:positive])}",
      upload_length: @size
    })
  end

  defp cleanup(row) do
    row
    |> Ecto.Changeset.change(cleanup_at: DateTime.utc_now(:second), upload_url: nil)
    |> Repo.update!()
  end
end
