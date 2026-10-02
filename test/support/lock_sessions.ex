defmodule Tips.LockSessions do
  @moduledoc """
  Committed transactions on their own database backends, driven step by step
  from a test, with the real lock wait observed through `pg_blocking_pids`.

  The sandbox is bypassed, so fixtures commit: delete them in `on_exit`.
  `lock_timeout` and the idle rollback bound every wait if the test fails.
  """

  import ExUnit.Assertions

  alias Ecto.Adapters.SQL.Sandbox
  alias Tips.Repo

  @doc "Runs `fun` on an unboxed connection, outside any test transaction."
  def unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  @doc "Opens a transaction on its own backend under the given `Task.Supervisor`."
  def open(supervisor) do
    parent = self()
    task = Task.Supervisor.async_nolink(supervisor, fn -> transaction(parent) end)
    pid = task.pid

    receive do
      {:backend, ^pid, backend} -> %{task: task, backend: backend}
    after
      1_000 -> flunk("transaction did not open")
    end
  end

  defp transaction(parent) do
    # Outlives the repo's query timeout: a session idles between its steps.
    unboxed(fn -> Repo.transaction(fn -> announce_and_serve(parent) end, timeout: 15_000) end)
  end

  defp announce_and_serve(parent) do
    Repo.query!("SET LOCAL lock_timeout = '4s'")
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    send(parent, {:backend, self(), backend})
    serve(parent)
  end

  defp serve(parent) do
    receive do
      {:run, ref, step} ->
        send(parent, {ref, step.()})
        serve(parent)

      :commit ->
        :committed
    after
      5_000 -> Repo.rollback(:abandoned)
    end
  end

  @doc "Starts `step` in the session's transaction and returns the ref its result is sent with."
  def submit(%{task: task}, step) do
    ref = make_ref()
    send(task.pid, {:run, ref, step})
    ref
  end

  @doc "Waits for the result of a submitted step."
  def await(%{task: task}, ref) do
    monitor = task.ref

    receive do
      {^ref, result} -> result
      {:DOWN, ^monitor, :process, _, reason} -> flunk("transaction exited: #{inspect(reason)}")
    after
      3_000 -> flunk("transaction step did not finish")
    end
  end

  @doc "Runs `step` in the session's transaction and returns its result."
  def run(session, step), do: await(session, submit(session, step))

  @doc "Commits the session's transaction."
  def commit(%{task: task}) do
    send(task.pid, :commit)
    assert {:ok, :committed} = Task.await(task)
  end

  @doc """
  Ends a session whose step was rejected. A rejected operation aborts the
  step's enclosing transaction, as nested Ecto transactions do; a top-level
  caller simply gets the error.
  """
  def roll_back(%{task: task}) do
    send(task.pid, :commit)
    assert {:error, :rollback} = Task.await(task)
  end

  @doc "Waits until `waiter` is blocked by a lock that one of `blockers` holds or awaits."
  def await_blocked(waiter, blockers) do
    blockers = blockers |> List.wrap() |> Enum.map(& &1.backend)
    unboxed(fn -> poll_blocked(waiter.backend, blockers, deadline()) end)
  end

  defp poll_blocked(waiter, blockers, deadline) do
    %{rows: [[blocked?]]} =
      Repo.query!("SELECT $1::integer[] && pg_blocking_pids($2::integer)", [blockers, waiter])

    unless blocked? do
      assert System.monotonic_time(:millisecond) < deadline,
             "expected backend #{waiter} to wait on #{inspect(blockers)}"

      Process.sleep(10)
      poll_blocked(waiter, blockers, deadline)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 1_000
end
