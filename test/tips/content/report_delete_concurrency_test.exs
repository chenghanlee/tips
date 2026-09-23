defmodule Tips.Content.ReportDeleteConcurrencyTest do
  # Database schedule slice only (#252, gate #38): report insertion versus author content
  # deletion on the full schema, with flag FKs and counter triggers active. The schedules
  # take the documented lock orders directly; they are not the application report or
  # author-delete operations. Production deletion also resolves the target's open flags,
  # so the flag that report-first leaves open here is expected in this slice and is
  # application work, not acceptance of it.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.ModerationFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Tips.Accounts.User
  alias Tips.Content.{Counters, Flag, Review, Tip, Visibility, Vote}
  alias Tips.Repo

  setup do
    data =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, data} =
          Repo.transaction(fn ->
            author = user_fixture()
            voter = user_fixture()
            confirmed = user_fixture()
            unconfirmed = unconfirmed_user_fixture()
            tip = tip_fixture(author)
            review = review_fixture(tip)
            vote_fixture(tip, %{user_id: voter.id})
            vote_fixture(review, %{user_id: voter.id})

            %{
              tip: tip,
              review: review,
              confirmed: confirmed,
              unconfirmed: unconfirmed,
              user_ids: [
                review.user_id | Enum.map([author, voter, confirmed, unconfirmed], & &1.id)
              ]
            }
          end)

        data
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.transaction(fn ->
          Repo.query!("ALTER TABLE votes DISABLE TRIGGER votes_counts")
          Repo.query!("ALTER TABLE reviews DISABLE TRIGGER reviews_counts")
          Repo.delete_all(from(f in Flag, where: f.user_id in ^data.user_ids))
          Repo.delete_all(from(v in Vote, where: v.user_id in ^data.user_ids))
          Repo.delete_all(from(r in Review, where: r.tip_id == ^data.tip.id))
          Repo.delete_all(from(t in Tip, where: t.id == ^data.tip.id))
          Repo.delete_all(from(u in User, where: u.id in ^data.user_ids))
          Repo.query!("ALTER TABLE reviews ENABLE TRIGGER reviews_counts")
          Repo.query!("ALTER TABLE votes ENABLE TRIGGER votes_counts")
        end)
      end)
    end)

    Map.put(data, :supervisor, start_supervised!(Task.Supervisor))
  end

  for target <- [:tip, :review],
      order <- [:report_first, :delete_first],
      reporter <- [:confirmed, :unconfirmed] do
    test "#{target} report/delete #{order} with #{reporter} reporter", data do
      content = Map.fetch!(data, unquote(target))
      reporter = Map.fetch!(data, unquote(reporter))
      reporting = open(data.supervisor)
      deleting = open(data.supervisor)
      refute reporting.backend == deleting.backend

      flagged? =
        schedule(unquote(order), unquote(reporter), reporting, deleting, reporter, content)

      assert_outcome(data, unquote(target), flagged?, reporter)
    end
  end

  # The report's FOR SHARE on the live target conflicts with deletion's row lock, so
  # deletion waits for the report to commit and then deletes the reported content.
  defp schedule(:report_first, :confirmed, reporting, deleting, reporter, content) do
    assert run(reporting, fn -> eligible?(reporter) end)
    assert :reported = run(reporting, fn -> report(reporter, content) end)
    deletion = submit(deleting, fn -> delete(content) end)
    await_blocked(deleting, reporting)
    commit(reporting)
    assert {1, _} = await(deleting, deletion)
    commit(deleting)
    true
  end

  # Rejected under the reporter lock before any target selection: deletion completes
  # while the rejected report transaction is still open.
  defp schedule(:report_first, :unconfirmed, reporting, deleting, reporter, content) do
    refute run(reporting, fn -> eligible?(reporter) end)
    assert {1, _} = run(deleting, fn -> delete(content) end)
    commit(deleting)
    commit(reporting)
    false
  end

  # The eligible selection waits on deletion's row lock; READ COMMITTED then rechecks
  # the live predicate on the deleted row version and finds nothing to report.
  defp schedule(:delete_first, :confirmed, reporting, deleting, reporter, content) do
    assert {1, _} = run(deleting, fn -> delete(content) end)
    assert run(reporting, fn -> eligible?(reporter) end)
    selection = submit(reporting, fn -> report(reporter, content) end)
    await_blocked(reporting, deleting)
    commit(deleting)
    assert :not_reportable = await(reporting, selection)
    commit(reporting)
    false
  end

  # Rejection needs only the reporter lock, so it completes while deletion holds the
  # target lock.
  defp schedule(:delete_first, :unconfirmed, reporting, deleting, reporter, content) do
    assert {1, _} = run(deleting, fn -> delete(content) end)
    refute run(reporting, fn -> eligible?(reporter) end)
    commit(reporting)
    commit(deleting)
    false
  end

  defp assert_outcome(data, target, flagged?, reporter) do
    Sandbox.unboxed_run(Repo, fn ->
      tip = Repo.reload!(data.tip)
      review = Repo.reload!(data.review)

      {deleted, kept, review_count} =
        if target == :tip, do: {tip, review, 1}, else: {review, tip, 0}

      assert %{deleted_at: %DateTime{}, dead_at: nil} = deleted
      assert :deleted = Visibility.decision(nil, deleted)
      assert :visible = Visibility.decision(nil, kept)
      assert_flags(flagged?, Repo.all(from(f in Flag, where: ^target_attrs(deleted))), reporter)
      assert %{up_count: 1, down_count: 0, review_count: ^review_count} = tip
      assert %{up_count: 1, down_count: 0} = review
      assert {0, 0} = Counters.recount!()
    end)
  end

  # This slice does not resolve flags; see the module comment.
  defp assert_flags(true, flags, %{id: reporter_id}),
    do: assert([%Flag{user_id: ^reporter_id, resolved_at: nil}] = flags)

  defp assert_flags(false, flags, _reporter), do: assert([] = flags)

  defp eligible?(%User{id: id}) do
    Repo.one!(
      from(u in User,
        where: u.id == ^id,
        lock: "FOR NO KEY UPDATE",
        select: not is_nil(u.confirmed_at) and is_nil(u.ban) and is_nil(u.deleted_at)
      )
    )
  end

  defp report(reporter, content) do
    %schema{id: id} = content

    reportable =
      from(c in schema,
        where: c.id == ^id and is_nil(c.deleted_at) and is_nil(c.dead_at),
        lock: "FOR SHARE",
        select: c.id
      )

    case Repo.all(reportable) do
      [^id] ->
        flag_fixture(reporter, target_attrs(content))
        :reported

      [] ->
        :not_reportable
    end
  end

  defp delete(%Tip{} = tip) do
    lock!(User, tip.user_id)
    soft_delete!(Tip, tip.id)
  end

  defp delete(%Review{} = review) do
    lock!(User, review.user_id)
    lock!(Tip, review.tip_id)
    soft_delete!(Review, review.id)
  end

  defp soft_delete!(schema, id) do
    lock!(schema, id)

    Repo.update_all(from(c in schema, where: c.id == ^id and is_nil(c.deleted_at)),
      set: [deleted_at: DateTime.utc_now(:second)]
    )
  end

  defp lock!(schema, id) do
    Repo.one!(from(r in schema, where: r.id == ^id, lock: "FOR NO KEY UPDATE", select: r.id))
  end

  defp target_attrs(%Tip{id: id}), do: [tip_id: id]
  defp target_attrs(%Review{id: id}), do: [review_id: id]

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
