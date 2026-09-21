defmodule Tips.Content.CountersConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Tips.Accounts.User
  alias Tips.Content.{Counters, Review, Tip, Vote}
  alias Tips.Repo

  setup do
    data =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, data} =
          Repo.transaction(fn ->
            author = user_fixture()
            up_voter = user_fixture()
            down_voter = user_fixture()
            tip = tip_fixture(author)

            review =
              Repo.insert!(%Review{
                tip_id: tip.id,
                user_id: up_voter.id,
                submission_key: Ecto.UUID.generate(),
                body: "A committed review for the counter race."
              })

            %{tip: tip, review: review, user_ids: [author.id, up_voter.id, down_voter.id]}
          end)

        data
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(v in Vote, where: v.user_id in ^data.user_ids))
        Repo.delete_all(from(r in Review, where: r.tip_id == ^data.tip.id))
        Repo.delete_all(from(t in Tip, where: t.id == ^data.tip.id))
        Repo.delete_all(from(u in User, where: u.id in ^data.user_ids))
      end)
    end)

    Map.put(data, :supervisor, start_supervised!(Task.Supervisor))
  end

  for target <- [:tip, :review] do
    test "overlapping committed votes keep #{target} counters correct", data do
      target = Map.fetch!(data, unquote(target))
      [_, up_voter, down_voter] = data.user_ids

      first = fn -> vote_fixture(target, %{user_id: up_voter, value: 1}) end
      second = fn -> vote_fixture(target, %{user_id: down_voter, value: -1}) end
      overlap_transactions(data.supervisor, first, second)

      Sandbox.unboxed_run(Repo, fn ->
        assert %{up_count: 1, down_count: 1, score: 0} = Repo.reload!(target)
        assert {0, 0} = Counters.recount!()
      end)
    end
  end

  for first <- [:hide, :bulk_restore] do
    test "review liveness and bulk locks commit when #{first} takes the parent first", data do
      hide = fn ->
        # Omitting this parent lock lets the review UPDATE deadlock against bulk's
        # tip-then-review locks: its trigger also needs the parent tip.
        lock_tip(data.tip)

        Repo.update_all(from(r in Review, where: r.id == ^data.review.id),
          set: [dead_at: DateTime.utc_now(:second)]
        )
      end

      bulk_restore = fn ->
        lock_tip(data.tip)
        Repo.one!(from(r in Review, where: r.id == ^data.review.id, lock: "FOR NO KEY UPDATE"))
        Repo.update_all(from(r in Review, where: r.id == ^data.review.id), set: [dead_at: nil])
      end

      {first, second, expected} =
        case unquote(first) do
          :hide -> {hide, bulk_restore, 1}
          :bulk_restore -> {bulk_restore, hide, 0}
        end

      overlap_transactions(data.supervisor, first, second)

      Sandbox.unboxed_run(Repo, fn ->
        assert %{review_count: ^expected} = Repo.reload!(data.tip)
        assert {0, 0} = Counters.recount!()
      end)
    end
  end

  defp lock_tip(tip) do
    Repo.one!(from(t in Tip, where: t.id == ^tip.id, lock: "FOR NO KEY UPDATE"))
  end

  defp overlap_transactions(supervisor, first_write, second_write) do
    parent = self()
    first = transaction_task(supervisor, parent, first_write, true)
    second = transaction_task(supervisor, parent, second_write, false)
    first_pid = first.pid
    second_pid = second.pid

    # Both independent transactions are open before either starts writing.
    assert_receive {:ready, ^first_pid, first_backend}, 1_000
    assert_receive {:ready, ^second_pid, second_backend}, 1_000
    refute first_backend == second_backend
    send(first_pid, :go)
    assert_receive {:written, ^first_pid}, 1_000
    send(second_pid, :go)

    # Observe the real database lock wait instead of relying on a scheduler race.
    Sandbox.unboxed_run(Repo, fn ->
      await_blocked(second_backend, first_backend, System.monotonic_time(:millisecond) + 1_000)
    end)

    send(first_pid, :commit)
    assert {:ok, :committed} = Task.await(first)
    assert {:ok, :committed} = Task.await(second)
  end

  defp transaction_task(supervisor, parent, write, hold?) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      unboxed_transaction(parent, write, hold?)
    end)
  end

  defp unboxed_transaction(parent, write, hold?) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn -> synchronized_write(parent, write, hold?) end)
    end)
  end

  defp synchronized_write(parent, write, hold?) do
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    send(parent, {:ready, self(), backend})
    await_message(:go)
    write.()
    send(parent, {:written, self()})
    if hold?, do: await_message(:commit)
    :committed
  end

  defp await_message(message) do
    receive do
      ^message -> :ok
    after
      1_500 -> flunk("transaction did not receive #{inspect(message)}")
    end
  end

  defp await_blocked(waiter, blocker, deadline) do
    %{rows: [[blocked?]]} =
      Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [blocker, waiter])

    unless blocked? do
      assert System.monotonic_time(:millisecond) < deadline,
             "expected an overlapping row lock wait"

      Process.sleep(10)
      await_blocked(waiter, blocker, deadline)
    end
  end
end
