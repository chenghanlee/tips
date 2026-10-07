defmodule Tips.Content.Search.EmbeddingsTest do
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures
  import Tips.SearchFixtures
  import Tips.VisibilityFixtures

  alias Tips.Content.Search.Embeddings
  alias Tips.Content.Tag

  test "scans attempt at most 50 alternating rows and cool failures without blocking later rows" do
    author = user_fixture()
    tips = for n <- 1..40, do: indexed_tip!(author, %{title: "Tip #{n}"})

    # A stored document over the provider's 30,000-byte input bound, which the
    # writers refuse; the provider still guards against one.
    Repo.query!("UPDATE tip_search SET search_text = $2 WHERE tip_id = $1", [
      Enum.at(tips, 3).id,
      "Tip 4\n" <> String.duplicate("é", 15_000)
    ])

    for {tip, n} <- tips |> Enum.take(20) |> Enum.with_index(1),
        do: indexed_review!(tip, %{body: "Review #{n}"})

    stub_provider(fn conn, input ->
      case first_line(input) do
        "Tip 2" -> Plug.Conn.send_resp(conn, 400, "rejected")
        "Review 3" -> Plug.Conn.send_resp(conn, 200, "not json")
        _other -> respond_vector(conn, input)
      end
    end)

    assert %{selected: 50, embedded: 47, skipped: 0, failed: failed} = Embeddings.scan()
    assert failed == %{{:http, 400} => 1, :malformed => 1, :too_large => 1}

    alternating = Enum.flat_map(1..20, &["Tip #{&1}", "Review #{&1}"]) -- ["Tip 4"]
    assert first_lines(provider_inputs()) == alternating ++ Enum.map(21..30, &"Tip #{&1}")

    assert %{selected: 10, embedded: 10, failed: %{}} = Embeddings.scan()
    assert first_lines(provider_inputs()) == Enum.map(31..40, &"Tip #{&1}")

    for n <- [2, 4] do
      assert %{embedding: nil, embed_after: %DateTime{} = due} =
               search_row({:tip, Enum.at(tips, n - 1).id})

      assert DateTime.after?(due, DateTime.utc_now())
    end

    assert %{selected: 0} = Embeddings.scan()
    assert provider_inputs() == []

    # A text change resets the cooldown, so the next scan admits the new text.
    edit!(Enum.at(tips, 1), body: "Rewritten so the provider accepts it.")
    stub_provider()
    assert %{selected: 1, embedded: 1} = Embeddings.scan()
    assert [input] = provider_inputs()
    assert input =~ "Rewritten so the provider accepts it."
  end

  test "never-attempted rows go first, then the oldest due retries" do
    author = user_fixture()
    tips = for n <- 1..60, do: indexed_tip!(author, %{title: "Tip #{n}"})

    reviews =
      for {tip, n} <- Enum.with_index(tips, 1), do: indexed_review!(tip, %{body: "Review #{n}"})

    stub_provider(fn conn, _input -> Plug.Conn.send_resp(conn, 400, "") end)

    scans = [1..25, 26..50, Enum.concat(51..60, 1..15), 16..40]

    for {batch, scan} <- Enum.with_index(scans, 1) do
      # Earlier cooldowns have elapsed, as when scans outlast them.
      if scan > 1, do: age_cooldowns!(tips, reviews, "11 minutes")

      assert %{selected: 50, failed: %{{:http, 400} => 50}} = Embeddings.scan()
      expected = Enum.flat_map(batch, &["Tip #{&1}", "Review #{&1}"])
      assert first_lines(provider_inputs()) == expected, "scan #{scan}"
    end
  end

  test "only live, due, unembedded documents are admitted, rechecked before each request" do
    author = user_fixture()

    [live, hidden, deleted, cooling, embedded, hidden_later, edited_later] =
      for title <- ~w(Live Hidden Deleted Cooling Embedded HiddenLater EditedLater),
          do: indexed_tip!(author, %{title: title})

    put_marker!(hidden, :hidden)
    put_marker!(deleted, :deleted)
    put_cooldown!({:tip, cooling.id}, 600)
    put_embedding!({:tip, embedded.id})

    live_review = indexed_review!(live, %{body: "LiveReview"})
    indexed_review!(hidden, %{body: "UnderHiddenTip"})
    indexed_review!(live, %{body: "HiddenReview"}) |> put_marker!(:hidden)
    indexed_review!(live, %{body: "DeletedReview"}) |> put_marker!(:deleted)

    stub_provider(fn conn, input ->
      if first_line(input) == "Live" do
        # Committed while this request runs: they do not recall it, but they
        # block admission of later candidates, including the live tip's review.
        put_marker!(live, :hidden)
        put_marker!(hidden_later, :hidden)
        edit!(edited_later, body: "Edited while an earlier request ran.")
      end

      respond_vector(conn, input)
    end)

    live_text = search_row({:tip, live.id}).text

    assert %{selected: 4, embedded: 1, skipped: 3} = Embeddings.scan()
    assert provider_inputs() == [live_text]
    assert %{embedding: "[" <> _} = search_row({:tip, live.id})

    for row <- [{:review, live_review.id}, {:tip, hidden_later.id}, {:tip, edited_later.id}] do
      assert %{embedding: nil, embed_after: nil} = search_row(row)
    end

    assert %{selected: 1, embedded: 1} = Embeddings.scan()
    assert ["EditedLater\nEdited while an earlier request ran." <> _] = provider_inputs()
  end

  test "stale or superseded results never change the row" do
    author = user_fixture()

    other_tag =
      Repo.insert!(%Tag{
        id: "retag-#{System.unique_integer([:positive])}",
        label: "Other",
        sort_order: 100
      })

    [edited, retagged, bumped, raced_success, raced_failure, control] =
      for title <- ~w(Edited Retagged Bumped RacedSuccess RacedFailure Control),
          do: indexed_tip!(author, %{title: title})

    review = indexed_review!(control, %{body: "EditedReview"})
    test = self()
    competing = "[" <> Enum.join([0, 1 | List.duplicate(0, 1022)], ",") <> "]"

    stub_provider(fn conn, input ->
      case first_line(input) do
        "Edited" ->
          edit!(edited, body: "A newer body.")
          respond_vector(conn, input)

        "Retagged" ->
          edit!(retagged, tag_id: other_tag.id)
          Plug.Conn.send_resp(conn, 503, "")

        "EditedReview" ->
          edit!(review, output: "A newer output.")
          respond_vector(conn, input)

        "Bumped" ->
          # The token moves by one microsecond only; the guard still rejects the write.
          Repo.query!(
            "UPDATE tip_search SET text_at = text_at + interval '1 microsecond' WHERE tip_id = $1",
            [bumped.id]
          )

          respond_vector(conn, input)

        "RacedSuccess" ->
          put_embedding!({:tip, raced_success.id}, competing)
          respond_vector(conn, input)

        "RacedFailure" ->
          put_embedding!({:tip, raced_failure.id}, competing)
          send(test, {:claimed, search_row({:tip, raced_failure.id}).embed_after})
          Plug.Conn.send_resp(conn, 500, "")

        "Control" ->
          respond_vector(conn, input)
      end
    end)

    assert %{selected: 7, embedded: 1, stale: 4, skipped: 0, failed: failed} = Embeddings.scan()
    assert failed == %{{:http, 503} => 1, {:http, 500} => 1}
    assert length(provider_inputs()) == 7

    for content <- [edited, retagged] do
      assert %{embedding: nil, embed_after: nil} = search_row({:tip, content.id})
    end

    assert %{embedding: nil, embed_after: nil} = search_row({:review, review.id})
    assert %{embedding: nil} = search_row({:tip, bumped.id})
    assert %{embedding: ^competing} = search_row({:tip, raced_success.id})

    assert_received {:claimed, claimed}
    assert %{embedding: ^competing, embed_after: ^claimed} = search_row({:tip, raced_failure.id})
    assert %{embedding: "[1," <> _} = search_row({:tip, control.id})

    # Edited documents wait for a later scan and are then embedded from current text.
    stub_provider()
    assert %{selected: 3, embedded: 3} = Embeddings.scan()
    inputs = provider_inputs()
    assert Enum.any?(inputs, &(&1 =~ "A newer body."))
    assert Enum.any?(inputs, &(&1 =~ "A newer output."))
  end

  defp age_cooldowns!(tips, reviews, interval) do
    for {table, column, rows} <- [
          {"tip_search", "tip_id", tips},
          {"review_search", "review_id", reviews}
        ] do
      Repo.query!(
        "UPDATE #{table} SET embed_after = embed_after - $2::text::interval WHERE #{column} = ANY($1)",
        [Enum.map(rows, & &1.id), interval]
      )
    end
  end

  defp first_line(input), do: input |> String.split("\n") |> hd()
end
