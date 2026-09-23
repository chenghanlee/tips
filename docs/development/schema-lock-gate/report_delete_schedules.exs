# Direct database schedules for report insertion versus author deletion (#38).
#
# Gate evidence, not a regression test: #28 owns the ExUnit fixture. Run against the
# migrated test database, never while `mix test` uses the same database:
#
#     unbuffer mix run --no-start docs/development/schema-lock-gate/report_delete_schedules.exs
#
# Each schedule opens two real transactions on separate backends and observes the lock
# wait with pg_blocking_pids before releasing the blocker. Rows are committed and removed
# at the end.

defmodule Gate38.Session do
  @moduledoc false

  # One open transaction on its own backend, driven step by step from the caller.
  def open(conn_opts) do
    parent = self()
    {:ok, conn} = Postgrex.start_link(conn_opts)

    pid =
      spawn_link(fn ->
        result = Postgrex.transaction(conn, &loop(&1, parent), timeout: :infinity)
        send(parent, {:finished, self(), result})
      end)

    session = %{pid: pid, conn: conn}
    {:ok, %{rows: [[backend]]}} = query(session, "SELECT pg_backend_pid()")
    {:ok, _} = query(session, "SET LOCAL lock_timeout = '3s'")
    Map.put(session, :backend, backend)
  end

  def submit(%{pid: pid}, sql, params \\ []) do
    ref = make_ref()
    send(pid, {:query, ref, sql, params})
    ref
  end

  def await(ref, timeout \\ 5_000) do
    receive do
      {^ref, result} -> result
    after
      timeout -> raise "query did not finish within #{timeout} ms"
    end
  end

  def query(session, sql, params \\ []), do: session |> submit(sql, params) |> await()

  def commit(%{pid: pid} = session) do
    send(pid, :commit)
    finish(session)
  end

  defp finish(%{pid: pid, conn: conn}) do
    receive do
      {:finished, ^pid, result} ->
        GenServer.stop(conn)
        result
    after
      5_000 -> raise "transaction did not finish"
    end
  end

  defp loop(conn, parent) do
    receive do
      {:query, ref, sql, params} ->
        send(parent, {ref, Postgrex.query(conn, sql, params)})
        loop(conn, parent)

      :commit ->
        :committed
    end
  end
end

defmodule Gate38.Schedules do
  @moduledoc false
  alias Gate38.Session

  @eligible_reporter """
  SELECT confirmed_at IS NOT NULL AND ban IS NULL AND deleted_at IS NULL
  FROM users WHERE id = $1 FOR NO KEY UPDATE
  """

  def run(conn_opts) do
    {:ok, db} = Postgrex.start_link(conn_opts)
    data = setup(db)

    try do
      results =
        for target <- [:tip, :review],
            order <- [:report_insert_first, :author_delete_first],
            reporter <- [:confirmed, :unconfirmed] do
          schedule(conn_opts, db, data, target, order, reporter)
        end

      controls = for target <- [:tip, :review], do: fk_only_control(conn_opts, db, data, target)
      Enum.each(results ++ controls, &IO.puts/1)

      IO.puts(
        "PASS: #{length(results)} report/delete schedules and #{length(controls)} FK-only controls"
      )
    after
      cleanup(db, data)
    end
  end

  # Report: lock and check the reporter, then select the live direct target FOR SHARE and
  # insert. Author deletion: lock the author, the parent tip, then the review if any.
  defp schedule(conn_opts, db, data, target, order, reporter) do
    content = content(db, data)
    sessions = %{reporter: Session.open(conn_opts), author: Session.open(conn_opts)}
    eligible? = reporter == :confirmed
    ^eligible? = eligible?(sessions.reporter, Map.fetch!(data, reporter))
    wait = run_order(order, eligible?, db, sessions, content, target)
    expected_flags = if order == :report_insert_first and eligible?, do: 1, else: 0
    assert_outcome!(db, content, target, expected_flags)

    "PASS #{target} #{order} #{reporter}: #{wait}; flags=#{expected_flags}; target deleted" <>
      review_count_note(db, content, target)
  end

  defp run_order(:report_insert_first, eligible?, db, sessions, content, target) do
    if eligible?, do: report(sessions.reporter, content, target)
    delete_ref = author_delete_async(sessions.author, content, target)
    wait = if eligible?, do: await_blocked(db, sessions.author, sessions.reporter)
    {:ok, :committed} = Session.commit(sessions.reporter)
    :ok = await_ok(delete_ref)
    {:ok, :committed} = Session.commit(sessions.author)
    wait_note(wait)
  end

  defp run_order(:author_delete_first, false, _db, sessions, content, target) do
    :ok = await_ok(author_delete_async(sessions.author, content, target))
    {:ok, :committed} = Session.commit(sessions.author)
    {:ok, :committed} = Session.commit(sessions.reporter)
    wait_note(nil)
  end

  defp run_order(:author_delete_first, true, db, sessions, content, target) do
    :ok = await_ok(author_delete_async(sessions.author, content, target))

    select_ref =
      Session.submit(sessions.reporter, select_target_sql(target), [id(content, target)])

    wait = await_blocked(db, sessions.reporter, sessions.author)
    {:ok, :committed} = Session.commit(sessions.author)
    # READ COMMITTED rechecks the live predicate on the deleted row version.
    {:ok, %{rows: []}} = Session.await(select_ref)
    {:ok, :committed} = Session.commit(sessions.reporter)
    wait_note(wait)
  end

  defp wait_note(nil), do: "no wait: reporter ineligible, no target lock taken"
  defp wait_note(wait), do: "observed wait #{wait}"

  # Without FOR SHARE the flag's FK check takes only FOR KEY SHARE on the target, which
  # does not conflict with the deleter's FOR NO KEY UPDATE, so a report lands on content
  # already deleted by a concurrent transaction.
  defp fk_only_control(conn_opts, db, data, target) do
    content = content(db, data)
    reporter_session = Session.open(conn_opts)
    author_session = Session.open(conn_opts)
    :ok = await_ok(author_delete_async(author_session, content, target))
    true = eligible?(reporter_session, data.confirmed)

    insert_ref =
      Session.submit(reporter_session, insert_sql(target), [id(content, target), data.confirmed])

    {:ok, %{num_rows: 1}} = Session.await(insert_ref, 2_000)
    {:ok, :committed} = Session.commit(author_session)
    {:ok, :committed} = Session.commit(reporter_session)
    assert_outcome!(db, content, target, 1)

    "CONTROL #{target} fk_only_without_share: insert did not wait; flag on deleted #{target} " <>
      "(FK FOR KEY SHARE does not serialize with FOR NO KEY UPDATE)"
  end

  defp eligible?(session, user_id) do
    {:ok, %{rows: [[eligible?]]}} = Session.query(session, @eligible_reporter, [user_id])
    eligible?
  end

  defp report(session, content, target) do
    {:ok, %{rows: [[_]]}} =
      Session.query(session, select_target_sql(target), [id(content, target)])

    {:ok, %{num_rows: 1}} =
      Session.query(session, insert_sql(target), [id(content, target), content.confirmed])
  end

  defp select_target_sql(:tip),
    do: "SELECT id FROM tips WHERE id = $1 AND deleted_at IS NULL AND dead_at IS NULL FOR SHARE"

  defp select_target_sql(:review),
    do:
      "SELECT id FROM reviews WHERE id = $1 AND deleted_at IS NULL AND dead_at IS NULL FOR SHARE"

  defp insert_sql(target),
    do:
      "INSERT INTO flags (#{target}_id, user_id, reason, created_at) VALUES ($1, $2, 'spam', now())"

  # Returns the ref of the last statement; earlier statements complete before it is sent.
  defp author_delete_async(session, content, :tip) do
    {:ok, _} =
      Session.query(session, "SELECT id FROM users WHERE id = $1 FOR NO KEY UPDATE", [
        content.author
      ])

    tip_delete(session, content)
  end

  defp author_delete_async(session, content, :review) do
    {:ok, _} =
      Session.query(session, "SELECT id FROM users WHERE id = $1 FOR NO KEY UPDATE", [
        content.reviewer
      ])

    {:ok, _} =
      Session.query(session, "SELECT id FROM tips WHERE id = $1 FOR NO KEY UPDATE", [content.tip])

    Session.submit(
      session,
      """
      WITH locked AS (SELECT id FROM reviews WHERE id = $1 FOR NO KEY UPDATE)
      UPDATE reviews SET deleted_at = now() FROM locked WHERE reviews.id = locked.id
      """,
      [content.review]
    )
  end

  defp tip_delete(session, content) do
    Session.submit(
      session,
      """
      WITH locked AS (SELECT id FROM tips WHERE id = $1 FOR NO KEY UPDATE)
      UPDATE tips SET deleted_at = now() FROM locked WHERE tips.id = locked.id
      """,
      [content.tip]
    )
  end

  defp await_ok(ref) do
    {:ok, _} = Session.await(ref)
    :ok
  end

  # Observe the real wait instead of relying on scheduling.
  defp await_blocked(db, waiter, blocker, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    %{rows: [[blocked?]]} =
      Postgrex.query!(db, "SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [
        blocker.backend,
        waiter.backend
      ])

    cond do
      blocked? ->
        %{rows: rows} =
          Postgrex.query!(
            db,
            """
            SELECT a.wait_event_type || ':' || a.wait_event, l.locktype, l.mode
            FROM pg_stat_activity a JOIN pg_locks l ON l.pid = a.pid AND NOT l.granted
            WHERE a.pid = $1
            """,
            [waiter.backend]
          )

        Enum.map_join(rows, ",", fn [event, type, mode] -> "#{event} #{type} #{mode}" end)

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        await_blocked(db, waiter, blocker, deadline)

      true ->
        raise "expected backend #{waiter.backend} to wait on #{blocker.backend}"
    end
  end

  defp assert_outcome!(db, content, target, expected_flags) do
    %{rows: [[^expected_flags, true]]} =
      Postgrex.query!(
        db,
        "SELECT (SELECT count(*)::int FROM flags WHERE #{target}_id = $1), " <>
          "(SELECT deleted_at IS NOT NULL FROM #{target}s WHERE id = $1)",
        [id(content, target)]
      )
  end

  defp review_count_note(_db, _content, :tip), do: ""

  defp review_count_note(db, content, :review) do
    %{rows: [[0]]} =
      Postgrex.query!(db, "SELECT review_count FROM tips WHERE id = $1", [content.tip])

    "; reviews_counts trigger set tip review_count 1 -> 0"
  end

  defp id(content, target), do: Map.fetch!(content, target)

  defp setup(db) do
    run = System.unique_integer([:positive])
    tag = "gate38-#{run}"
    Postgrex.query!(db, "INSERT INTO tags (id, label, sort_order) VALUES ($1, $1, 999)", [tag])

    users =
      for {role, confirmed?} <- [
            author: true,
            reviewer: true,
            confirmed: true,
            unconfirmed: false
          ],
          into: %{} do
        %{rows: [[id]]} =
          Postgrex.query!(
            db,
            """
            INSERT INTO users (handle, email, confirmed_at, inserted_at, updated_at)
            VALUES ($1, $1 || '@example.com', CASE WHEN $2 THEN now() END, now(), now())
            RETURNING id
            """,
            ["g38-#{role}-#{run}", confirmed?]
          )

        {role, id}
      end

    Map.put(users, :tag, tag)
  end

  defp content(db, data) do
    %{rows: [[tip]]} =
      Postgrex.query!(
        db,
        """
        INSERT INTO tips (user_id, submission_key, title, body, tag_id, created_at)
        VALUES ($1, gen_random_uuid(), 'Gate 38 tip', 'Gate 38 body', $2, now()) RETURNING id
        """,
        [data.author, data.tag]
      )

    %{rows: [[review]]} =
      Postgrex.query!(
        db,
        """
        INSERT INTO reviews (tip_id, user_id, submission_key, body, created_at)
        VALUES ($1, $2, gen_random_uuid(), 'Gate 38 review', now()) RETURNING id
        """,
        [tip, data.reviewer]
      )

    %{
      tip: tip,
      review: review,
      author: data.author,
      reviewer: data.reviewer,
      confirmed: data.confirmed
    }
  end

  defp cleanup(db, data) do
    ids = [data.author, data.reviewer, data.confirmed, data.unconfirmed]

    Postgrex.transaction(db, fn conn ->
      Postgrex.query!(conn, "DELETE FROM flags WHERE user_id = ANY($1)", [ids])
      Postgrex.query!(conn, "DELETE FROM reviews WHERE user_id = ANY($1)", [ids])
      Postgrex.query!(conn, "DELETE FROM tips WHERE user_id = ANY($1)", [ids])
      Postgrex.query!(conn, "DELETE FROM users WHERE id = ANY($1)", [ids])
      Postgrex.query!(conn, "DELETE FROM tags WHERE id = $1", [data.tag])
    end)
  end
end

{:ok, _} = Application.ensure_all_started(:postgrex)

conn_opts =
  :tips
  |> Application.fetch_env!(Tips.Repo)
  |> Keyword.take([:hostname, :port, :username, :password, :database])

IO.puts("Database: #{conn_opts[:database]} on port #{conn_opts[:port]}")
Gate38.Schedules.run(conn_opts)
