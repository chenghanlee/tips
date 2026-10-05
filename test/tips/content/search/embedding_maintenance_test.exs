defmodule Tips.Content.Search.EmbeddingMaintenanceTest do
  use Tips.EmbeddingCase, async: false

  import Tips.VisibilityFixtures

  alias Tips.Content.Search.Embeddings

  test "a model switch drains and stops the old release, clears every vector, then restarts",
       %{author: author} do
    test = self()

    [live, hidden, pending] =
      for title <- ~w(Live Hidden Pending), do: indexed_tip!(author, %{title: title})

    cooling = indexed_review!(live, %{body: "Cooling"})
    deleted = indexed_review!(live, %{body: "Deleted"})

    for row <- [{:tip, live.id}, {:tip, hidden.id}, {:review, deleted.id}],
        do: put_embedding!(row)

    put_marker!(hidden, :hidden)
    put_marker!(deleted, :deleted)
    put_cooldown!({:review, cooling.id}, 600)

    rows = [
      {:tip, live.id},
      {:tip, hidden.id},
      {:tip, pending.id},
      {:review, cooling.id},
      {:review, deleted.id}
    ]

    # The old release is mid-scan, its request still running.
    stub_provider(fn conn, input ->
      send(test, {:requesting, self()})
      receive do: (:release -> respond_vector(conn, input))
    end)

    old = start_oban!()
    {:ok, old_scan} = insert_scan(old)
    assert_receive {:requesting, request}, 5_000
    request_ref = Process.monitor(request)

    # 1. Drain: no new scan starts and the running one finishes, then stop.
    :ok = Oban.pause_queue(old, queue: :embeddings)
    send(request, :release)
    await_state(old_scan, "completed")
    assert_receive {:DOWN, ^request_ref, :process, ^request, _reason}
    assert %{paused: true, running: []} = Oban.check_queue(old, queue: :embeddings)
    assert ["Pending" <> _] = provider_inputs()
    stop_supervised!(old)

    # 2. Clear, including hidden and deleted rows and the old scan's vector.
    tokens = Map.new(rows, &{&1, search_row(&1).token})
    assert %{tips: _, reviews: _} = Tips.Release.clear_embeddings()

    for row <- rows do
      assert %{embedding: nil, embed_after: nil, token: token} = search_row(row)
      assert DateTime.after?(token, tokens[row])
    end

    # 3–4. Restart with the matched policy; only live documents are embedded again.
    stub_provider()
    {:ok, restarted} = start_oban!() |> insert_scan()
    await_state(restarted, "completed")
    assert ["Live" <> _, "Cooling", "Pending" <> _] = provider_inputs()

    for row <- [{:tip, live.id}, {:tip, pending.id}, {:review, cooling.id}],
        do: assert(%{embedding: "[" <> _} = search_row(row))

    for row <- [{:tip, hidden.id}, {:review, deleted.id}],
        do: assert(%{embedding: nil} = search_row(row))
  end

  test "a request missed by the drain cannot write after the clear", %{author: author} do
    test = self()
    tip = indexed_tip!(author, %{title: "InFlight"})

    stub_provider(fn conn, input ->
      send(test, {:requesting, self()})
      receive do: (:release -> respond_vector(conn, input))
    end)

    missed = Task.async(fn -> Embeddings.scan() end)
    assert_receive {:requesting, request}

    Tips.Release.clear_embeddings()
    send(request, :release)

    assert %{embedded: 0, stale: 1} = Task.await(missed)
    assert %{embedding: nil} = search_row({:tip, tip.id})
  end

  test "the clear outlasts the request timeout and commits all or nothing", %{author: author} do
    test = self()
    tip = indexed_tip!(author, %{title: "Embedded"})
    review = indexed_review!(tip, %{body: "Locked"})
    for row <- [{:tip, tip.id}, {:review, review.id}], do: put_embedding!(row)

    blocker =
      Task.async(fn ->
        Repo.transact(
          fn ->
            Repo.query!("SELECT 1 FROM review_search WHERE review_id = $1 FOR UPDATE", [review.id])

            send(test, :locked)
            receive do: (:release -> {:ok, :released})
          end,
          timeout: 10_000
        )
      end)

    assert_receive :locked
    clear = Task.async(fn -> Tips.Release.clear_embeddings() end)

    # Hold the clear past the 2-second request timeout. Its tip update is not
    # visible while it waits for the review row.
    Process.sleep(2_100)
    assert %{embedding: "[" <> _} = search_row({:tip, tip.id})

    send(blocker.pid, :release)
    assert {:ok, :released} = Task.await(blocker)
    assert %{tips: _, reviews: _} = Task.await(clear)

    for row <- [{:tip, tip.id}, {:review, review.id}],
        do: assert(%{embedding: nil} = search_row(row))
  end
end
