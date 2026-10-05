defmodule Tips.Content.Search.EmbeddingMaintenanceTest do
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures
  import Tips.SearchFixtures
  import Tips.VisibilityFixtures

  alias Tips.Content.Search.Embeddings

  test "a model switch clears every vector, and a request from before the clear cannot write" do
    test = self()
    author = user_fixture()

    [live, hidden, in_flight] =
      for title <- ~w(Live Hidden InFlight), do: indexed_tip!(author, %{title: title})

    review = indexed_review!(live, %{body: "Cooling"})
    deleted_review = indexed_review!(live, %{body: "Deleted"})

    for row <- [{:tip, live.id}, {:tip, hidden.id}, {:review, deleted_review.id}],
        do: put_embedding!(row)

    put_marker!(hidden, :hidden)
    put_marker!(deleted_review, :deleted)
    put_cooldown!({:review, review.id}, 600)

    # An old-model scan that was not drained: admitted, its request still running.
    stub_provider(fn conn, input ->
      send(test, {:requesting, self()})
      receive do: (:release -> respond_vector(conn, input))
    end)

    old_scan = Task.async(fn -> Embeddings.scan() end)
    assert_receive {:requesting, request}

    rows = [
      {:tip, live.id},
      {:tip, hidden.id},
      {:tip, in_flight.id},
      {:review, review.id},
      {:review, deleted_review.id}
    ]

    before = Map.new(rows, &{&1, search_row(&1).token})

    assert %{tips: _, reviews: _} = Tips.Release.clear_embeddings()

    for row <- rows do
      assert %{embedding: nil, embed_after: nil, token: token} = search_row(row)
      assert DateTime.after?(token, before[row])
    end

    send(request, :release)
    assert %{embedded: 0, stale: 1} = Task.await(old_scan)
    assert %{embedding: nil} = search_row({:tip, in_flight.id})

    # Restarted with the matched model: every live document is embedded again.
    stub_provider()
    assert %{selected: 3, embedded: 3} = Embeddings.scan()

    for row <- [{:tip, live.id}, {:tip, in_flight.id}, {:review, review.id}],
        do: assert(%{embedding: "[" <> _} = search_row(row))

    for row <- [{:tip, hidden.id}, {:review, deleted_review.id}],
        do: assert(%{embedding: nil} = search_row(row))
  end
end
