defmodule Tips.Content.MediaSchemaTest do
  use Tips.DataCase, async: true

  alias Tips.Content.Media.Target

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures

  describe "media constraint matrix" do
    test "rejects unknown kinds at the database boundary" do
      user = user_fixture()

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            "INSERT INTO media (user_id, kind, created_at) VALUES ($1, 'audio', $2)",
            [user.id, DateTime.utc_now(:second)]
          )
        end

      assert error.postgres.code == :check_violation
      assert error.postgres.constraint == "media_kind_vals"
    end

    test "rejects unknown video states at the database boundary" do
      user = user_fixture()
      uuid = Ecto.UUID.generate()
      now = DateTime.utc_now(:second)

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            """
            INSERT INTO media (user_id, kind, state, target, created_at, expires_at)
            VALUES ($1, 'video', 'done', $2, $3, $4)
            """,
            [user.id, "new_tip:#{uuid}", now, DateTime.add(now, 3600)]
          )
        end

      assert error.postgres.code == :check_violation
      assert error.postgres.constraint == "media_state_vals"
    end

    test "media_storage_chk rejects invalid image storage shapes" do
      image = image_fixture(tip_fixture())

      for attrs <- [%{state: :uploading}, %{key: nil}, %{is_animated: nil}] do
        assert_raise Ecto.ConstraintError, ~r/media_storage_chk/, fn ->
          image |> change(attrs) |> Repo.update!()
        end
      end
    end

    test "media_storage_chk rejects invalid video storage shapes" do
      staged = staged_video_fixture(user_fixture())

      for attrs <- [
            %{description: "not allowed"},
            %{key: "media/#{Ecto.UUID.generate()}.png"},
            %{target: nil},
            %{state: :processing, stream_uid: nil},
            %{state: nil},
            %{is_animated: false}
          ] do
        assert_raise Ecto.ConstraintError, ~r/media_storage_chk/, fn ->
          staged |> change(attrs) |> Repo.update!()
        end
      end
    end

    test "media_ready_chk requires trusted completion and a duration in (0, 180]" do
      video = staged_video_fixture(user_fixture(), ready_video_attrs())

      for attrs <- [
            %{duration_s: 0.0},
            %{duration_s: 180.5},
            %{duration_s: nil},
            %{completed_at: nil},
            %{stream_uid: nil}
          ] do
        assert_raise Ecto.ConstraintError, ~r/media_ready_chk/, fn ->
          video |> change(attrs) |> Repo.update!()
        end
      end
    end

    test "media_one_parent rejects rows belonging to a tip and review" do
      tip = tip_fixture()
      review = review_fixture(tip)
      media = cleanup_media_fixture(tip)

      assert_raise Ecto.ConstraintError, ~r/media_one_parent/, fn ->
        media |> change(review_id: review.id) |> Repo.update!()
      end
    end

    test "media_lifecycle_chk rejects invalid attachment and cleanup shapes" do
      tip = tip_fixture()
      attached = attached_video_fixture(tip)
      staged = staged_video_fixture(user_fixture())
      image = image_fixture(tip, %{position: 1})
      cleanup = cleanup_media_fixture(tip, %{position: 2})

      invalid_updates = [
        {image, %{tip_id: nil}},
        {attached, %{expires_at: DateTime.add(attached.created_at, 3600)}},
        {attached, %{state: :processing}},
        {staged, %{expires_at: nil}},
        {cleanup, %{position: 0}},
        {attached, %{position: nil}}
      ]

      for {media, attrs} <- invalid_updates do
        assert_raise Ecto.ConstraintError, ~r/media_lifecycle_chk/, fn ->
          media |> change(attrs) |> Repo.update!()
        end
      end
    end

    test "media_position_chk enforces slots 0 through 9" do
      image = image_fixture(tip_fixture())

      for position <- [-1, 10] do
        assert_raise Ecto.ConstraintError, ~r/media_position_chk/, fn ->
          image |> change(position: position) |> Repo.update!()
        end
      end
    end

    test "media_key_chk accepts only canonical media keys and supported extensions" do
      image = image_fixture(tip_fixture())

      for key <- ["media/x.png", "media/#{Ecto.UUID.generate()}.bmp"] do
        assert_raise Ecto.ConstraintError, ~r/media_key_chk/, fn ->
          image |> change(key: key) |> Repo.update!()
        end
      end

      for extension <- ~w(png jpg webp gif) do
        key = "media/#{Ecto.UUID.generate()}.#{extension}"
        assert %{key: ^key} = image_fixture(tip_fixture(), %{key: key})
      end
    end

    test "media_description_chk rejects blank image descriptions" do
      image = image_fixture(tip_fixture())

      assert_raise Ecto.ConstraintError, ~r/media_description_chk/, fn ->
        image |> change(description: " \t\n ") |> Repo.update!()
      end
    end

    test "media_reconcile_chk limits cooldowns to live unattached videos" do
      cooldown = DateTime.add(DateTime.utc_now(:second), 600)
      tip = tip_fixture()

      for media <- [
            attached_video_fixture(tip),
            image_fixture(tip, %{position: 1}),
            cleanup_media_fixture(tip, %{position: 2})
          ] do
        assert_raise Ecto.ConstraintError, ~r/media_reconcile_chk/, fn ->
          media |> change(reconcile_after: cooldown) |> Repo.update!()
        end
      end
    end

    test "accepts duration and position boundaries" do
      tip = tip_fixture()

      assert %{duration_s: 0.001, position: 0} =
               attached_video_fixture(tip, %{duration_s: 0.001, position: 0})

      assert %{duration_s: 180.0, position: 9} =
               attached_video_fixture(tip, %{duration_s: 180.0, position: 9})
    end
  end

  describe "accepted lifecycle rows" do
    test "accepts every staged video state allowed by the persistence model" do
      user = user_fixture()
      now = DateTime.utc_now(:second)

      assert %{state: :failed, stream_uid: nil} = staged_video_fixture(user, %{state: :failed})
      assert %{state: :uploading, stream_uid: nil} = staged_video_fixture(user)

      assert %{state: :processing, stream_uid: uid} =
               staged_video_fixture(user, %{state: :processing, stream_uid: unique_stream_uid()})

      assert is_binary(uid)

      assert %{state: :ready, stream_uid: ready_uid} =
               staged_video_fixture(user, ready_video_attrs())

      assert is_binary(ready_uid)

      assert %{reconcile_after: ^now} =
               staged_video_fixture(user, %{reconcile_after: now})
    end

    test "accepts attached and cleanup rows without losing provider identity" do
      tip = tip_fixture()

      assert %{kind: :video, state: :ready, tip_id: tip_id, expires_at: nil} =
               attached_video_fixture(tip)

      assert tip_id == tip.id

      assert %{kind: :image, description: nil, is_animated: false} =
               image_fixture(tip, %{position: 1})

      assert %{kind: :image, description: "Animated evidence", is_animated: true} =
               image_fixture(tip, %{
                 position: 2,
                 description: "Animated evidence",
                 is_animated: true
               })

      cleanup_video = cleanup_media_fixture(tip, %{position: 3})

      assert %{
               kind: :video,
               tip_id: ^tip_id,
               stream_uid: stream_uid,
               cleanup_at: %DateTime{},
               position: nil
             } = cleanup_video

      assert is_binary(stream_uid)

      cleanup_image = image_fixture(tip, %{position: 3})

      cleanup_image =
        cleanup_image
        |> change(cleanup_at: DateTime.utc_now(:second), position: nil)
        |> Repo.update!()

      assert %{kind: :image, key: key, tip_id: ^tip_id, position: nil} = cleanup_image
      assert is_binary(key)
    end

    test "Ecto enums round trip as atoms" do
      video = attached_video_fixture(tip_fixture()) |> Repo.reload!()
      assert %{kind: :video, state: :ready} = video
    end
  end

  describe "provider and relational identity" do
    test "provider identities remain unique after cleanup" do
      tip = tip_fixture()
      image = image_fixture(tip)
      image |> change(cleanup_at: DateTime.utc_now(:second), position: nil) |> Repo.update!()

      assert_raise Ecto.ConstraintError, ~r/media_key_unique/, fn ->
        image_fixture(tip_fixture(), %{key: image.key})
      end

      video = cleanup_media_fixture(tip)

      assert_raise Ecto.ConstraintError, ~r/media_stream_unique/, fn ->
        attached_video_fixture(tip_fixture(), %{stream_uid: video.stream_uid})
      end
    end

    test "foreign keys reject unknown users and parents" do
      for {fixture, constraint} <- [
            {fn -> staged_video_fixture(user_fixture(), %{user_id: -1}) end,
             "media_user_id_fkey"},
            {fn -> image_fixture(tip_fixture(), %{tip_id: -1}) end, "media_tip_id_fkey"},
            {fn -> image_fixture(review_fixture(), %{review_id: -1}) end, "media_review_id_fkey"}
          ] do
        assert_raise Ecto.ConstraintError, ~r/#{constraint}/, fixture
      end
    end
  end

  describe "deferrable attachment slots" do
    test "tip and review slots reject immediate collisions" do
      for {parent, constraint} <- parent_cases() do
        first = image_fixture(parent, %{position: 0})
        second = attached_video_fixture(parent, %{position: 1})

        assert_raise Ecto.ConstraintError, ~r/#{constraint}/, fn ->
          second |> change(position: first.position) |> Repo.update!()
        end
      end
    end

    test "tip and review slots can be swapped after deferral" do
      for {parent, constraint} <- parent_cases() do
        first = image_fixture(parent, %{position: 0})
        second = attached_video_fixture(parent, %{position: 1})

        assert {:ok, {swapped_first, swapped_second}} =
                 Repo.transact(fn ->
                   Repo.query!("SET CONSTRAINTS #{constraint} DEFERRED")
                   first |> change(position: 1) |> Repo.update!()
                   second |> change(position: 0) |> Repo.update!()
                   Repo.query!("SET CONSTRAINTS #{constraint} IMMEDIATE")
                   {:ok, {Repo.reload!(first), Repo.reload!(second)}}
                 end)

        assert {swapped_first.position, swapped_second.position} == {1, 0}
      end
    end

    test "tip and review slots reject invalid final duplicates when forced immediate" do
      for {parent, constraint} <- parent_cases() do
        first = image_fixture(parent, %{position: 0})
        attached_video_fixture(parent, %{position: 1})

        error =
          assert_raise Postgrex.Error, fn ->
            Repo.transact(fn ->
              Repo.query!("SET CONSTRAINTS #{constraint} DEFERRED")
              first |> change(position: 1) |> Repo.update!()
              Repo.query!("SET CONSTRAINTS #{constraint} IMMEDIATE")
              {:ok, :unreachable}
            end)
          end

        assert error.postgres.code == :unique_violation
        assert error.postgres.constraint == constraint
      end
    end

    test "ten live slots are available per parent and cleanup rows release them" do
      tip = tip_fixture()
      first_cleanup = cleanup_media_fixture(tip)
      second_cleanup = cleanup_media_fixture(tip)

      assert %{position: nil, tip_id: tip_id} = first_cleanup
      assert %{position: nil, tip_id: ^tip_id} = second_cleanup

      for position <- 0..9 do
        if rem(position, 2) == 0 do
          image_fixture(tip, %{position: position})
        else
          attached_video_fixture(tip, %{position: position})
        end
      end

      assert_raise Ecto.ConstraintError, ~r/media_position_chk/, fn ->
        image_fixture(tip, %{position: 10})
      end

      assert %{position: 0} = image_fixture(tip_fixture(), %{position: 0})
    end
  end

  describe "lifecycle persistence" do
    test "the same video row moves from staged ready through attachment to cleanup" do
      user = user_fixture()
      tip = tip_fixture(user)

      staged =
        staged_video_fixture(
          user,
          Map.merge(ready_video_attrs(), %{reconcile_after: DateTime.utc_now(:second)})
        )

      original = Map.take(staged, [:id, :target, :stream_uid])

      attached =
        staged
        |> change(tip_id: tip.id, position: 0, expires_at: nil, reconcile_after: nil)
        |> Repo.update!()

      cleaned =
        attached
        |> change(cleanup_at: DateTime.utc_now(:second), position: nil)
        |> Repo.update!()
        |> Repo.reload!()

      assert Map.take(cleaned, [:id, :target, :stream_uid]) == original
      assert %{tip_id: tip_id, cleanup_at: %DateTime{}, position: nil} = cleaned
      assert tip_id == tip.id
    end
  end

  describe "typed upload target" do
    test "all target shapes round trip through their canonical wire form" do
      uuid = Ecto.UUID.generate()

      for {target, wire} <- [
            {{:new_tip, uuid}, "new_tip:#{uuid}"},
            {{:new_review, 12, uuid}, "new_review:12:#{uuid}"},
            {{:edit_tip, 34}, "edit_tip:34"},
            {{:edit_review, 56}, "edit_review:56"}
          ] do
        assert {:ok, ^target} = Target.cast(target)
        assert {:ok, ^wire} = Target.dump(target)
        assert {:ok, ^target} = Target.load(wire)
      end
    end

    test "cast and dump reject browser strings, malformed tuples, ids and UUIDs" do
      uuid = Ecto.UUID.generate()
      binary_uuid = Ecto.UUID.dump!(uuid)

      for invalid <- [
            "new_tip:#{uuid}",
            {:new_tip, "bad"},
            {:new_tip, binary_uuid},
            {:new_review, 0, uuid},
            {:new_review, -1, uuid},
            {:new_review, "1", uuid},
            {:edit_tip, 0},
            {:edit_tip, 9_223_372_036_854_775_808},
            {:edit_review, -1},
            {:unknown, 1},
            {:edit_tip, 1, :extra}
          ] do
        assert :error = Target.cast(invalid)
        assert :error = Target.dump(invalid)
      end
    end

    test "uppercase UUID input is normalized before persistence" do
      uppercase = Ecto.UUID.generate() |> String.upcase()
      lowercase = String.downcase(uppercase)

      assert {:ok, {:new_tip, ^lowercase}} = Target.cast({:new_tip, uppercase})
      assert {:ok, "new_tip:" <> ^lowercase} = Target.dump({:new_tip, uppercase})
    end

    test "accepts the PostgreSQL bigint id boundary" do
      max_id = 9_223_372_036_854_775_807

      assert {:ok, {:edit_tip, ^max_id}} = Target.cast({:edit_tip, max_id})
      assert {:ok, "edit_tip:9223372036854775807"} = Target.dump({:edit_tip, max_id})
      assert {:ok, {:edit_tip, ^max_id}} = Target.load("edit_tip:9223372036854775807")
    end

    test "load rejects noncanonical and malformed stored forms" do
      uuid = Ecto.UUID.generate()

      for invalid <- [
            "edit_tip:abc",
            "edit_tip:0",
            "edit_tip:+1",
            "edit_tip:01",
            "edit_review: 1",
            "new_tip:#{String.upcase(uuid)}",
            "new_tip:bad",
            "new_tip:#{uuid}:extra",
            "new_review:#{uuid}",
            "new_review:1:bad",
            "new_review:01:#{uuid}",
            "edit_tip:9223372036854775808",
            "other:1",
            <<0::128>>,
            nil
          ] do
        assert :error = Target.load(invalid)
      end
    end

    test "target tuples persist and raw storage is canonical text" do
      uppercase = Ecto.UUID.generate() |> String.upcase()
      expected_uuid = String.downcase(uppercase)
      video = staged_video_fixture(user_fixture(), %{target: {:new_tip, uppercase}})

      assert %{target: {:new_tip, ^expected_uuid}} = Repo.reload!(video)

      assert %{rows: [["new_tip:" <> ^expected_uuid]]} =
               Repo.query!("SELECT target FROM media WHERE id = $1", [video.id])
    end

    test "direct struct inserts reject invalid target tuples through dump/1" do
      assert_raise Ecto.ChangeError, ~r/does not match type/, fn ->
        staged_video_fixture(user_fixture(), %{target: {:edit_tip, 0}})
      end
    end
  end

  test "media_expiry uses only static predicates" do
    assert %{rows: [[definition]]} =
             Repo.query!(
               "SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'media_expiry'"
             )

    assert definition =~ "(expires_at, id)"
    assert definition =~ "kind = 'video'"
    assert definition =~ "cleanup_at IS NULL"
    assert definition =~ "tip_id IS NULL"
    assert definition =~ "review_id IS NULL"
    refute definition =~ "now()"
    refute definition =~ "clock_timestamp()"
  end

  defp ready_video_attrs do
    %{
      state: :ready,
      stream_uid: unique_stream_uid(),
      duration_s: 12.5,
      completed_at: DateTime.utc_now(:second)
    }
  end

  defp unique_stream_uid, do: "stream-#{Ecto.UUID.generate()}"

  defp parent_cases do
    tip = tip_fixture()
    [{tip, "media_tip_slot"}, {review_fixture(tip), "media_review_slot"}]
  end
end
