defmodule Tips.Workers.SweepOrphanImagesTest do
  # Sets the R2 call bound in the application environment and attaches telemetry.
  use Tips.DataCase, async: false

  import Tips.R2Stub

  alias Tips.Content.Media.R2
  alias Tips.Workers.SweepOrphanImages

  @old ~U[2026-01-01 00:00:00Z]

  setup do
    test = self()
    handler = "sweep-orphan-images-#{inspect(test)}"

    :telemetry.attach(
      handler,
      [:oban, :job, :start],
      fn _event, _measurements, %{job: job}, _config -> send(test, {:started, job.args}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "one job carries the token through six pages and holds the uniqueness slot" do
    test = self()
    tokens = [nil | Enum.map(1..5, &"page-#{&1}")]
    orphans = Enum.map(tokens, fn _token -> image_key() end)
    nexts = tl(tokens) ++ [nil]

    # A weekly tick while page 2 executes.
    stub(
      [tokens, orphans, nexts]
      |> Enum.zip_with(fn [token, orphan, next] -> {token, {[{orphan, @old}], next}} end)
      |> Map.new()
      |> Map.update!("page-2", fn page ->
        fn ->
          send(test, {:tick_while_executing, Oban.insert(SweepOrphanImages.new(%{}))})
          page
        end
      end)
    )

    {:ok, %{id: id} = job} = Oban.insert(SweepOrphanImages.new(%{}))

    assert %{snoozed: 1} = Oban.drain_queue(queue: :maintenance)
    assert %{state: "scheduled", args: %{"after" => "page-1"}} = Repo.reload!(job)
    assert {:ok, %{id: ^id, conflict?: true}} = Oban.insert(SweepOrphanImages.new(%{}))

    assert %{snoozed: 4, success: 1, discard: 0} =
             Oban.drain_queue(queue: :maintenance, with_scheduled: true, with_recursion: true)

    assert started() == [%{} | Enum.map(tl(tokens), &%{"after" => &1})]
    assert_received {:tick_while_executing, {:ok, %{id: ^id, conflict?: true}}}
    assert deletes() == orphans
    assert %{state: "completed"} = Repo.reload!(job)
  end

  test "a listing error on a later page discards the job" do
    orphan = image_key()
    stub(%{nil => {[{orphan, @old}], "page-1"}, "page-1" => 500})

    {:ok, job} = Oban.insert(SweepOrphanImages.new(%{}))

    assert %{snoozed: 1, discard: 1} =
             Oban.drain_queue(queue: :maintenance, with_scheduled: true, with_recursion: true)

    assert %{state: "discarded"} = Repo.reload!(job)
    assert deletes() == [orphan]
  end

  test "a listing that outlives the call bound discards the job and leaves no request running" do
    env = Application.fetch_env!(:tips, R2)
    Application.put_env(:tips, R2, Keyword.put(env, :call_timeout, 100))
    on_exit(fn -> Application.put_env(:tips, R2, env) end)
    stub(%{nil => :block})

    {:ok, job} = Oban.insert(SweepOrphanImages.new(%{}))

    assert %{discard: 1} = Oban.drain_queue(queue: :maintenance)
    assert %{state: "discarded"} = Repo.reload!(job)
    assert_received {:blocked, request}
    refute Process.alive?(request)
  end

  defp started do
    receive do
      {:started, args} -> [args | started()]
    after
      0 -> []
    end
  end
end
