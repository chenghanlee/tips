defmodule Tips.RepoTimeoutTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Tips.Repo

  @moduletag :capture_log

  test "request deadline survives a maintenance query on the pool" do
    assert_request_timeout()

    Sandbox.unboxed_run(Repo, fn ->
      {elapsed, result} = :timer.tc(fn -> Repo.maintenance_query!("SELECT pg_sleep(3)") end)
      assert %{num_rows: 1} = result
      assert elapsed >= 3_000_000
    end)

    assert_request_timeout()
  end

  test "maintenance query accepts parameters and an explicit timeout" do
    Sandbox.unboxed_run(Repo, fn ->
      assert %{rows: [[42]]} = Repo.maintenance_query!("SELECT $1::integer", [42])

      error =
        try do
          Repo.maintenance_query!("SELECT pg_sleep(3)", [], timeout: 100)
        rescue
          error in [DBConnection.ConnectionError, Postgrex.Error] -> error
        end

      assert_timeout_error(error)
    end)
  end

  defp assert_request_timeout do
    Sandbox.unboxed_run(Repo, fn ->
      {elapsed, result} = :timer.tc(fn -> Repo.query("SELECT pg_sleep(3)") end)
      assert {:error, error} = result
      assert_timeout_error(error)
      assert elapsed >= 2_000_000
      assert elapsed < 2_500_000
    end)
  end

  # Postgrex sends CancelRequest before closing a timed-out connection. Either
  # the cancellation response or the socket close can reach the caller first.
  defp assert_timeout_error(%DBConnection.ConnectionError{}), do: :ok

  defp assert_timeout_error(error) do
    assert %Postgrex.Error{postgres: %{code: :query_canceled}} = error
  end
end
