defmodule Tips.Content.MediaTest do
  use ExUnit.Case, async: true

  alias Tips.Content.Media
  alias Tips.Content.Media.R2

  @moduletag :tmp_dir
  @fixtures Path.expand("../../fixtures/images", __DIR__)

  # Copies a fixture to a page-owned path under the client's file name.
  defp file(dir, fixture, filename) do
    path = Path.join(dir, filename)
    File.cp!(Path.join(@fixtures, fixture), path)
    %{path: path, filename: filename}
  end

  defp sparse(dir, filename, size) do
    path = Path.join(dir, filename)
    {:ok, io} = File.open(path, [:write])
    {:ok, _} = :file.position(io, size)
    :ok = :file.truncate(io)
    File.close(io)
    %{path: path, filename: filename}
  end

  # Records each request and answers with `reply.(method, key, count)`.
  defp stub_r2(reply) do
    test = self()

    Req.Test.stub(R2, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      "/tips-test/" <> key = conn.request_path
      send(test, {:r2, conn.method, key, Map.new(conn.req_headers), body})

      case reply.(conn.method, key) do
        :timeout -> Req.Test.transport_error(conn, :timeout)
        status -> Plug.Conn.send_resp(conn, status, "")
      end
    end)
  end

  defp requests do
    receive do
      {:r2, method, key, headers, body} -> [{method, key, headers, body} | requests()]
    after
      0 -> []
    end
  end

  test "stores new images under fresh keys with types from their content", %{tmp_dir: dir} do
    stub_r2(fn "PUT", _key -> 200 end)
    photo = file(dir, "static.jpg", "photo.png")
    loop = file(dir, "animated.webp", "loop.gif")

    selection = [
      {:retained, 5, "kept"},
      {:image_file, "a", photo, "  "},
      {:staged_video, 7},
      {:image_file, "b", loop, "A loop"}
    ]

    assert {:ok,
            [
              %{slot: "a", key: "media/" <> photo_name, content_type: "image/jpeg"} = first,
              %{slot: "b", key: "media/" <> loop_name, content_type: "image/webp"} = second
            ]} = Media.store_images(selection)

    assert %{is_animated: false, description: nil} = first
    assert %{is_animated: true, description: "A loop"} = second
    assert [_uuid, "jpg"] = String.split(photo_name, ".")
    assert [_uuid, "webp"] = String.split(loop_name, ".")

    assert [
             {"PUT", key_a, %{"content-type" => "image/jpeg"} = headers, body_a},
             {"PUT", key_b, %{"content-type" => "image/webp"}, body_b}
           ] = requests()

    assert {key_a, key_b} == {first.key, second.key}
    assert {body_a, body_b} == {File.read!(photo.path), File.read!(loop.path)}
    assert headers["cache-control"] == "public, max-age=3600, must-revalidate"

    assert {:ok, [%{key: retry_a}, %{key: retry_b}]} = Media.store_images(selection)
    assert MapSet.disjoint?(MapSet.new([retry_a, retry_b]), MapSet.new([key_a, key_b]))
  end

  test "rejects invalid, unsupported and oversized files before storing any", %{tmp_dir: dir} do
    stub_r2(fn method, key -> flunk("unexpected #{method} #{key}") end)
    gif = File.read!(Path.join(@fixtures, "animated.gif"))
    File.write!(Path.join(dir, "cut.gif"), binary_part(gif, 0, 100))
    File.write!(Path.join(dir, "notes.png"), "plain text")

    selection = [
      {:image_file, "ok", file(dir, "static.png", "fine.png"), nil},
      {:image_file, "cut", %{path: Path.join(dir, "cut.gif"), filename: "cut.gif"}, nil},
      {:image_file, "text", %{path: Path.join(dir, "notes.png"), filename: "notes.png"}, nil},
      {:image_file, "big", sparse(dir, "big.png", 10_000_001), nil}
    ]

    assert {:error,
            {:rejected_images, [{"cut", :invalid}, {"text", :unsupported}, {"big", :too_large}]}} =
             Media.store_images(selection)

    assert requests() == []
  end

  test "limits the combined selection and the new bytes", %{tmp_dir: dir} do
    stub_r2(fn method, key -> flunk("unexpected #{method} #{key}") end)
    retained = for id <- 1..10, do: {:retained, id, nil}
    image = {:image_file, "new", file(dir, "static.png", "new.png"), nil}

    assert {:error, :too_many_attachments} = Media.store_images([image | retained])
    # Without new images, no R2 client is built: these settings could not build one.
    assert {:ok, []} = Media.store_images(retained, settings: %{})

    nine_mb = for n <- 1..6, do: {:image_file, "#{n}", sparse(dir, "#{n}.png", 9_000_000), nil}
    assert {:error, :too_many_new_bytes} = Media.store_images(nine_mb ++ Enum.take(retained, 4))
    assert requests() == []
  end

  test "a later put failure deletes only the objects known to be stored", %{tmp_dir: dir} do
    stub_r2(fn
      "PUT", _key -> if Process.put(:put, true), do: :timeout, else: 200
      "DELETE", _key -> 204
    end)

    selection =
      for slot <- ~w(a b c), do: {:image_file, slot, file(dir, "static.png", "#{slot}.png"), nil}

    assert {:error, {:upload_failed, ["b"]}} = Media.store_images(selection)
    assert [{"PUT", stored, _, _}, {"PUT", unknown, _, _}, {"DELETE", deleted, _, _}] = requests()
    assert deleted == stored
    refute unknown == stored
  end

  @tag :real_provider
  test "an object round-trips through R2", %{tmp_dir: dir} do
    client = R2.client!(plug: nil, settings: nil)
    key = "media/test-62/#{System.system_time(:millisecond)}/#{Ecto.UUID.generate()}.png"
    bytes = File.read!(file(dir, "static.png", "a.png").path)

    try do
      assert :ok = R2.put(client, key, bytes, "image/png")
      assert {:ok, %{status: 200, body: ^bytes} = got} = Req.get(client, url: "/" <> key)
      assert Req.Response.get_header(got, "content-type") == ["image/png"]
    after
      assert :ok = R2.delete(client, key)
    end

    assert {:ok, %{status: 404}} = Req.get(client, url: "/" <> key)
  end
end
