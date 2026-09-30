defmodule Tips.Accounts.SessionFamilyConcurrencyTest do
  # Two browser responses renew the same predecessor concurrently. Each renewal runs on its
  # own backend; the second waits on the first's account lock, then revalidates the
  # predecessor and joins the same family.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Tips.Accounts
  alias Tips.Accounts.{User, UserToken}
  alias Tips.Repo

  setup do
    {user, predecessor} =
      Sandbox.unboxed_run(Repo, fn ->
        user = user_fixture()
        {user, Accounts.generate_user_session_token(user)}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(u in User, where: u.id == ^user.id))
      end)
    end)

    %{user: user, predecessor: predecessor, supervisor: start_supervised!(Task.Supervisor)}
  end

  test "concurrent renewals produce two valid successors in the original family", data do
    %{user: user, predecessor: predecessor} = data
    first = open(data.supervisor)
    second = open(data.supervisor)
    refute first.backend == second.backend

    assert {:ok, first_token} =
             run(first, fn -> Accounts.renew_user_session_token(user, predecessor) end)

    renewal = submit(second, fn -> Accounts.renew_user_session_token(user, predecessor) end)
    await_blocked(second, first)
    commit(first)
    assert {:ok, second_token} = await(second, renewal)
    commit(second)

    Sandbox.unboxed_run(Repo, fn ->
      family = session_row(predecessor).session_family_id
      refute first_token == second_token

      for token <- [predecessor, first_token, second_token] do
        assert %UserToken{session_family_id: ^family} = session_row(token)
        assert {%User{}, _} = Accounts.get_user_by_session_token(token)
      end
    end)
  end

  defp session_row(token), do: Repo.get_by!(UserToken, token: token, context: "session")

  # One committed transaction on its own backend, driven step by step from the test.
  # lock_timeout and the idle rollback bound every wait if the test process fails.
  defp open(supervisor) do
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
    Sandbox.unboxed_run(Repo, fn -> Repo.transaction(fn -> announce_and_serve(parent) end) end)
  end

  defp announce_and_serve(parent) do
    Repo.query!("SET LOCAL lock_timeout = '2s'")
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

  defp submit(%{task: task}, step) do
    ref = make_ref()
    send(task.pid, {:run, ref, step})
    ref
  end

  defp await(%{task: task}, ref) do
    monitor = task.ref

    receive do
      {^ref, result} -> result
      {:DOWN, ^monitor, :process, _, reason} -> flunk("transaction exited: #{inspect(reason)}")
    after
      3_000 -> flunk("transaction step did not finish")
    end
  end

  defp run(session, step), do: await(session, submit(session, step))

  defp commit(%{task: task}) do
    send(task.pid, :commit)
    assert {:ok, :committed} = Task.await(task)
  end

  # Observe the real database lock wait instead of relying on a scheduler race.
  defp await_blocked(waiter, blocker) do
    Sandbox.unboxed_run(Repo, fn ->
      await_blocked(waiter.backend, blocker.backend, System.monotonic_time(:millisecond) + 1_000)
    end)
  end

  defp await_blocked(waiter, blocker, deadline) do
    %{rows: [[blocked?]]} =
      Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [blocker, waiter])

    unless blocked? do
      assert System.monotonic_time(:millisecond) < deadline,
             "expected backend #{waiter} to wait on #{blocker}"

      Process.sleep(10)
      await_blocked(waiter, blocker, deadline)
    end
  end
end
