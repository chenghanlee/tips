defmodule Tips.Accounts.RegistrationConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.DataCase, only: [errors_on: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Tips.Accounts
  alias Tips.Accounts.User
  alias Tips.Repo

  setup do
    handle = "Race#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from(u in User, where: fragment("lower(?)", u.handle) == ^String.downcase(handle))
        )
      end)
    end)

    %{handle: handle, supervisor: start_supervised!(Task.Supervisor)}
  end

  test "concurrent case-variant handle claims produce one user and one handle error", %{
    handle: handle,
    supervisor: supervisor
  } do
    parent = self()

    # The first claim inserts inside an open transaction and holds it.
    first =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            send(parent, {:backend, self(), backend_pid()})
            result = Accounts.register_user(%{handle: handle, email: unique_user_email()})
            send(parent, {:inserted, self()})
            receive do: (:commit -> result)
          end)
        end)
      end)

    first_pid = first.pid
    assert_receive {:backend, ^first_pid, first_backend}, 1_000
    assert_receive {:inserted, ^first_pid}, 1_000

    # The second claim uses a different connection and waits on the uncommitted row.
    second =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Sandbox.unboxed_run(Repo, fn ->
          send(parent, {:backend, self(), backend_pid()})
          Accounts.register_user(%{handle: String.downcase(handle), email: unique_user_email()})
        end)
      end)

    second_pid = second.pid
    assert_receive {:backend, ^second_pid, second_backend}, 1_000
    refute first_backend == second_backend

    Sandbox.unboxed_run(Repo, fn ->
      await_blocked(second_backend, first_backend, System.monotonic_time(:millisecond) + 1_000)
    end)

    send(first_pid, :commit)

    assert {:ok, {:ok, %User{handle: ^handle}}} = Task.await(first)
    assert {:error, changeset} = Task.await(second)
    assert %{handle: ["has already been taken"]} = errors_on(changeset)

    Sandbox.unboxed_run(Repo, fn ->
      assert [%User{handle: ^handle}] =
               Repo.all(
                 from(u in User,
                   where: fragment("lower(?)", u.handle) == ^String.downcase(handle)
                 )
               )
    end)
  end

  defp backend_pid do
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  defp await_blocked(waiter, blocker, deadline) do
    %{rows: [[blocked?]]} =
      Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [blocker, waiter])

    unless blocked? do
      assert System.monotonic_time(:millisecond) < deadline,
             "expected the second claim to wait on the first"

      Process.sleep(10)
      await_blocked(waiter, blocker, deadline)
    end
  end
end
