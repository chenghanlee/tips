defmodule Tips.Content.Media.VideoUploadTest do
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  alias Tips.Accounts.Scope
  alias Tips.Content
  alias Tips.Content.Media.{Asset, CloudflareStream}

  @size 12_345_678

  setup do
    user = user_fixture()
    %{user: user, scope: Scope.for_user(user)}
  end

  # Records each reservation request in the test process and answers with `reply.(conn)`.
  defp stub_stream(reply) do
    test = self()

    Req.Test.stub(CloudflareStream, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test, {:stream, conn.method, conn.request_path, conn.query_params, conn.req_headers})
      reply.(conn)
    end)
  end

  defp reserved(conn, uid \\ "uid#{System.unique_integer([:positive])}") do
    conn
    |> Plug.Conn.put_resp_header("location", "https://upload.test/tus/#{uid}?tusv2=true")
    |> Plug.Conn.put_resp_header("stream-media-id", uid)
    |> Plug.Conn.send_resp(201, "")
  end

  defp no_request do
    stub_stream(fn conn -> flunk("unexpected #{conn.method} #{conn.request_path}") end)
  end

  defp requests do
    receive do
      {:stream, method, path, query, headers} -> [{method, path, query, headers} | requests()]
    after
      0 -> []
    end
  end

  defp metadata(headers) do
    {"upload-metadata", value} = List.keyfind(headers, "upload-metadata", 0)

    Map.new(String.split(value, ","), fn pair ->
      case String.split(pair, " ") do
        [key] -> {key, true}
        [key, encoded] -> {key, Base.decode64!(encoded)}
      end
    end)
  end

  defp side_effect_counts do
    for table <- ~w(tips reviews votes notifications flags tip_search review_search),
        into: %{},
        do: {table, Repo.aggregate(table, :count)}
  end

  test "stores the uid of a private 180-second reservation before releasing its URL", data do
    key = Ecto.UUID.generate()
    test = self()

    stub_stream(fn conn ->
      # The row exists before the call, and no transaction holds locks during it.
      send(test, {:during_call, Repo.all(Asset), Repo.in_transaction?()})
      reserved(conn, "abc123")
    end)

    other = user_fixture()
    # Identity and provider fields in the file attrs are ignored.
    attrs = %{size: @size, user_id: other.id, stream_uid: "forged", target: {:edit_tip, 1}}

    assert {:ok, %{media_id: id, upload_url: url, expires_at: expires_at}} =
             Content.begin_video_upload(data.scope, {:new_tip, String.upcase(key)}, attrs)

    assert url == "https://upload.test/tus/abc123?tusv2=true"
    assert_received {:during_call, [%Asset{id: ^id, stream_uid: nil, state: :uploading}], false}

    assert %Asset{
             user_id: user_id,
             kind: :video,
             state: :uploading,
             stream_uid: "abc123",
             target: {:new_tip, ^key},
             upload_length: @size,
             upload_url: ^url,
             created_at: created_at,
             expires_at: ^expires_at,
             tip_id: nil,
             review_id: nil,
             position: nil,
             cleanup_at: nil
           } = Repo.get!(Asset, id)

    assert user_id == data.user.id
    assert DateTime.diff(expires_at, created_at) == 3600

    assert [{"POST", "/client/v4/accounts/synthetic-account/stream", query, headers}] =
             requests()

    assert query == %{"direct_user" => "true"}
    assert {"authorization", "Bearer synthetic-stream-token"} in headers
    assert {"tus-resumable", "1.0.0"} in headers
    assert {"upload-length", "12345678"} in headers

    assert metadata(headers) == %{
             "maxDurationSeconds" => "180",
             "requiresignedurls" => true,
             "expiry" => DateTime.to_iso8601(expires_at),
             "name" => "tips-media-#{id}"
           }
  end

  test "binds each target kind to the author's eligible content", data do
    stub_stream(&reserved/1)
    tip = tip_fixture(data.user)
    hidden_tip = tip_fixture(data.user, %{dead_at: DateTime.utc_now(:second)})
    review = review_fixture(tip_fixture(), %{user_id: data.user.id})
    # Review edits do not depend on the parent.
    orphan =
      review_fixture(tip_fixture(user_fixture(), %{deleted_at: DateTime.utc_now(:second)}), %{
        user_id: data.user.id
      })

    key = Ecto.UUID.generate()

    targets = [
      {:new_review, tip.id, key},
      {:edit_tip, tip.id},
      {:edit_tip, hidden_tip.id},
      {:edit_review, review.id},
      {:edit_review, orphan.id}
    ]

    for target <- targets do
      assert {:ok, %{media_id: id}} = Content.begin_video_upload(data.scope, target, %{size: 1})
      assert %Asset{target: ^target, state: :uploading} = Repo.get!(Asset, id)
    end
  end

  test "rejects ineligible callers and targets before any provider call or row", data do
    no_request()
    stranger = user_fixture()
    now = DateTime.utc_now(:second)
    others_tip = tip_fixture(stranger)
    others_review = review_fixture(others_tip, %{user_id: stranger.id})
    deleted_tip = tip_fixture(data.user, %{deleted_at: now})
    deleted_review = review_fixture(others_tip, %{user_id: data.user.id, deleted_at: now})
    hidden_parent = tip_fixture(stranger, %{dead_at: now})
    key = Ecto.UUID.generate()

    for target <- [
          {:edit_tip, others_tip.id},
          {:edit_review, others_review.id},
          {:edit_tip, deleted_tip.id},
          {:edit_review, deleted_review.id},
          {:edit_tip, 9_000_000_000},
          {:new_review, hidden_parent.id, key},
          {:new_review, deleted_tip.id, key},
          {:new_review, 9_000_000_000, key}
        ] do
      assert Content.begin_video_upload(data.scope, target, %{size: 1}) == {:error, :not_found},
             inspect(target)
    end

    assert Content.begin_video_upload(nil, {:new_tip, key}, %{size: 1}) ==
             {:error, :unauthenticated}

    unconfirmed = Scope.for_user(unconfirmed_user_fixture())

    assert Content.begin_video_upload(unconfirmed, {:new_tip, key}, %{size: 1}) ==
             {:error, :unconfirmed}

    assert Repo.aggregate(Asset, :count) == 0
  end

  test "rejects a client-encoded target and an invalid size", data do
    no_request()
    key = Ecto.UUID.generate()

    for {target, attrs, errors} <- [
          {"new_tip:#{key}", %{size: 1}, %{target: ["is invalid"]}},
          {{:edit_tip, "1"}, %{size: 1}, %{target: ["is invalid"]}},
          {{:new_tip, "not-a-key"}, %{size: 1}, %{target: ["is invalid"]}},
          {{:new_tip, key}, %{}, %{size: ["can't be blank"]}},
          {{:new_tip, key}, %{size: 0}, %{size: ["must be greater than 0"]}},
          {{:new_tip, key}, %{size: 1_000_000_001},
           %{size: ["must be less than or equal to 1000000000"]}},
          {{:new_tip, key}, :bad, %{size: ["can't be blank"]}}
        ] do
      assert {:error, changeset} = Content.begin_video_upload(data.scope, target, attrs)
      assert errors_on(changeset) == errors
    end

    assert Repo.aggregate(Asset, :count) == 0
  end

  test "a published submission key returns its publication instead of an upload", data do
    no_request()
    tip = tip_fixture(data.user)
    review = review_fixture(tip, %{user_id: data.user.id})
    deleted = tip_fixture(data.user, %{deleted_at: DateTime.utc_now(:second)})
    tip_id = tip.id

    assert {:error, {:published, %{kind: :tip, id: ^tip_id, state: :live}}} =
             Content.begin_video_upload(data.scope, {:new_tip, tip.submission_key}, %{size: 1})

    assert {:error, {:published, %{kind: :review, id: review_id, tip_id: ^tip_id}}} =
             Content.begin_video_upload(
               data.scope,
               {:new_review, tip.id, review.submission_key},
               %{size: 1}
             )

    assert review_id == review.id

    assert {:error, {:published, %{state: :deleted}}} =
             Content.begin_video_upload(data.scope, {:new_tip, deleted.submission_key}, %{size: 1})

    # The key names this author's review of another tip.
    assert Content.begin_video_upload(
             data.scope,
             {:new_review, tip_fixture().id, review.submission_key},
             %{size: 1}
           ) == {:error, :conflict}

    # Another author's key grants nothing and is not reported.
    others = tip_fixture()
    stub_stream(&reserved/1)

    assert {:ok, %{media_id: _id}} =
             Content.begin_video_upload(data.scope, {:new_tip, others.submission_key}, %{size: 1})

    assert Repo.aggregate(Asset, :count) == 1
  end

  test "reserving changes no content, vote, notification, report or search row", data do
    stub_stream(&reserved/1)
    tip = tip_fixture()
    before = side_effect_counts()

    assert {:ok, _upload} =
             Content.begin_video_upload(
               data.scope,
               {:new_review, tip.id, Ecto.UUID.generate()},
               %{size: 1}
             )

    assert side_effect_counts() == before
  end

  test "a definite provisioning failure fails the row with no uid and is not retried", data do
    stub_stream(&Plug.Conn.send_resp(&1, 400, ~s({"errors":[{"code":10005}]})))
    key = Ecto.UUID.generate()

    assert {:error, {:upload_failed, [id]}} =
             Content.begin_video_upload(data.scope, {:new_tip, key}, %{size: 1})

    assert %Asset{state: :failed, stream_uid: nil, cleanup_at: nil} = Repo.get!(Asset, id)
    assert [_one] = requests()

    # A fresh upload gets a new row.
    stub_stream(&reserved/1)

    assert {:ok, %{media_id: fresh}} =
             Content.begin_video_upload(data.scope, {:new_tip, key}, %{size: 1})

    refute fresh == id
    assert %Asset{state: :failed, stream_uid: nil} = Repo.get!(Asset, id)
  end

  for lost <- [:timeout, :no_uid] do
    test "a lost provisioning response (#{lost}) releases nothing and keeps the row unfinished",
         data do
      lost = unquote(lost)
      stub_stream(&lost_response(&1, lost))

      assert {:error, {:upload_failed, [id]}} =
               Content.begin_video_upload(data.scope, {:new_tip, Ecto.UUID.generate()}, %{size: 1})

      assert %Asset{state: :uploading, stream_uid: nil, cleanup_at: nil} = Repo.get!(Asset, id)
      assert [_one] = requests()
    end
  end

  defp lost_response(conn, :timeout), do: Req.Test.transport_error(conn, :timeout)
  defp lost_response(conn, :no_uid), do: Plug.Conn.send_resp(conn, 201, "")

  # Each change commits while the provider call runs. Sandbox `now()` is the test
  # transaction's start, so only a wall-clock check sees the deadline at its moment.
  for {name, change} <- [
        deadline: [created_at: :deadline_now],
        cleanup: [cleanup_at: :now],
        failure: [state: :failed]
      ] do
    test "a response after #{name} never stores the uid or releases the URL", data do
      change = unquote(change)

      stub_stream(fn conn ->
        for asset <- Repo.all(Asset), do: late_change(asset, change)
        reserved(conn)
      end)

      assert {:error, {:upload_failed, [id]}} =
               Content.begin_video_upload(data.scope, {:new_tip, Ecto.UUID.generate()}, %{size: 1})

      assert %Asset{stream_uid: nil} = Repo.get!(Asset, id)
    end
  end

  # The deadline becomes the current wall time: past by the time the uid is persisted.
  # One statement time keeps `media_deadline_chk`'s one-hour difference exact.
  defp late_change(asset, created_at: :deadline_now) do
    from(a in Asset,
      where: a.id == ^asset.id,
      update: [
        set: [
          created_at: fragment("statement_timestamp() - interval '1 hour'"),
          expires_at: fragment("statement_timestamp()")
        ]
      ]
    )
    |> Repo.update_all([])
  end

  defp late_change(asset, change) do
    change = Keyword.replace(change, :cleanup_at, DateTime.utc_now(:second))
    asset |> Ecto.Changeset.change(change) |> Repo.update!()
  end

  test "admission spends the upload budget before reserving", data do
    stub_stream(&reserved/1)

    for _attempt <- 1..20 do
      assert {:ok, _upload} =
               Content.begin_video_upload(data.scope, {:new_tip, Ecto.UUID.generate()}, %{size: 1})
    end

    assert {:error, {:rate_limited, seconds}} =
             Content.begin_video_upload(data.scope, {:new_tip, Ecto.UUID.generate()}, %{size: 1})

    assert seconds > 0
    assert length(requests()) == 20
    assert Repo.aggregate(Asset, :count) == 20
  end
end
