defmodule Tips.Content.MediaSchemaTest do
  use Tips.DataCase, async: true

  alias Tips.Content.Media.Target

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures

  describe "media constraint matrix" do
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
