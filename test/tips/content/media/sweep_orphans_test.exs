defmodule Tips.Content.Media.SweepOrphansTest do
  use Tips.DataCase, async: true

  import ExUnit.CaptureLog
  import Tips.ContentFixtures
  import Tips.MediaFixtures
  import Tips.R2Stub

  alias Tips.Content.Media
  alias Tips.Content.Media.R2

  @old ~U[2026-01-01 00:00:00Z]
  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  test "deletes only old objects that no media row references, cleanup rows included" do
    tip = tip_fixture()
    attached = image_fixture(tip)
    cleanup = image_fixture(tip, position: nil, cleanup_at: DateTime.utc_now(:second))
    [orphan, young] = [image_key(), image_key()]

    stub(%{
      nil =>
        {[
           {orphan, @old},
           {attached.key, @old},
           {cleanup.key, @old},
           {young, DateTime.utc_now()}
         ], nil}
    })

    assert {:ok, %{deleted: 1, failed: 0}} = Media.sweep_orphans(nil)
    assert deletes() == [orphan]

    assert_received {:list,
                     %{"list-type" => "2", "prefix" => "media/", "max-keys" => "10"} = params,
                     _pid}

    refute Map.has_key?(params, "continuation-token")
  end

  test "never deletes keys outside the prefix or the key pattern" do
    uuid = Ecto.UUID.generate()

    keys = [
      "other/#{uuid}.png",
      "media/#{uuid}.png.bak",
      "media/#{uuid}.svg",
      "media/#{String.upcase(uuid)}.png",
      "media/test-62/1/#{uuid}.png",
      "xmedia/#{uuid}.png"
    ]

    stub(%{nil => {Enum.map(keys, &{&1, @old}), nil}})

    assert {:ok, %{deleted: 0, failed: 0}} = Media.sweep_orphans(nil)
    assert deletes() == []
  end

  test "checks references on each page; a failed delete is counted and the page goes on" do
    tip = tip_fixture()
    [first_ref, second_ref] = [image_fixture(tip), image_fixture(tip, position: 1)]
    [first, failing, second] = [image_key(), image_key(), image_key()]

    stub(
      %{
        nil => {[{first, @old}, {first_ref.key, @old}], "page-2"},
        "page-2" => {[{failing, @old}, {second_ref.key, @old}, {second, @old}], nil}
      },
      fn key -> if key == failing, do: 500, else: 204 end
    )

    assert {:continue, "page-2"} = Media.sweep_orphans(nil)
    assert deletes() == [first]

    log =
      capture_log(fn ->
        assert {:ok, %{deleted: 1, failed: 1}} = Media.sweep_orphans("page-2")
      end)

    assert deletes() == [failing, second]
    assert log =~ failing
    assert_received {:list, %{"continuation-token" => "page-2"}, _pid}
  end

  test "a listing error deletes nothing" do
    stub(%{nil => {[{image_key(), @old}], "page-2"}, "page-2" => 503})

    assert {:continue, "page-2"} = Media.sweep_orphans(nil)
    assert [_first] = deletes()
    assert {:error, {:http, 503}} = Media.sweep_orphans("page-2")
    assert deletes() == []
  end

  @tag :capture_log
  test "deletes that outlive the call bound do not hold up the next page" do
    slow = for _ <- 1..10, do: image_key()
    orphan = image_key()

    stub(
      %{
        nil => {Enum.map(slow, &{&1, @old}), "page-2"},
        "page-2" => {[{orphan, @old}], nil}
      },
      fn key -> if key in slow, do: :block, else: 204 end
    )

    assert {:continue, "page-2"} = Media.sweep_orphans(nil, call_timeout: 50)
    assert deletes() == slow
    assert_dead_blocked(10)

    assert {:ok, %{deleted: 1, failed: 0}} = Media.sweep_orphans("page-2", call_timeout: 50)
    assert deletes() == [orphan]
  end

  test "a listing that outlives the call bound times out and leaves no request running" do
    stub(%{nil => :block})

    assert {:error, :timeout} = Media.sweep_orphans(nil, call_timeout: 50)
    assert_dead_blocked(1)
    assert deletes() == []
  end

  @tag :real_provider
  test "sweeps an old object from the real bucket and keeps a newer one" do
    real = [plug: nil, settings: nil]
    client = R2.client!(real)
    prefix = "media/test-69-#{System.system_time(:millisecond)}/"
    [old, new] = [image_key(prefix), image_key(prefix)]
    bytes = File.read!(Path.join(@fixtures, "static.png"))

    try do
      assert :ok = R2.put(client, old, bytes, "image/png")
      # Last-modified times may be whole seconds.
      Process.sleep(1_100)
      assert :ok = R2.put(client, new, bytes, "image/png")

      # The cutoff is the newer object's own time on the provider's clock.
      assert {:ok, %{objects: [_, _] = objects, next: nil}} = R2.list(client, prefix, nil)
      cutoff = Enum.find_value(objects, &(&1.key == new and &1.last_modified))

      assert {:ok, %{deleted: 1, failed: 0}} =
               Media.sweep_orphans(nil, real ++ [prefix: prefix, cutoff: cutoff])

      assert {:ok, %{status: 404}} = Req.get(client, url: "/" <> old)
      assert {:ok, %{status: 200}} = Req.get(client, url: "/" <> new)
    after
      assert :ok = R2.delete(client, old)
      assert :ok = R2.delete(client, new)
    end

    assert {:ok, %{objects: []}} = R2.list(client, prefix, nil)
  end

  # Task.shutdown/2 returns only after the killed request has exited.
  defp assert_dead_blocked(count) do
    for _ <- 1..count do
      assert_received {:blocked, pid}
      refute Process.alive?(pid)
    end
  end
end
