defmodule Tips.Content.Search.Embeddings do
  @moduledoc """
  Fills missing document vectors in bounded scans, and clears them all for a
  model change.

  ## Scanning

  `scan/1` runs from `Tips.Workers.EmbedSearch`, one scan at a time. It reads
  at most 50 candidates: live documents with no vector and no pending
  cooldown, by id within each kind, alternating tips and reviews while both
  remain, then the rest of the other kind. A review counts as live only when
  its tip is live too. Nothing replenishes the list during the scan.

  With no candidates the scan returns at once and needs no provider
  configuration. Otherwise it resolves the provider client first; a missing
  key raises before any row changes.

  Each candidate is then admitted by one guarded update that rechecks the
  candidate is still live, unembedded, due and at the token read, and sets a
  ten-minute cooldown. It returns the stored search text, which is the only
  provider input, so browser drafts and older text never reach the provider.
  A candidate that fails the recheck is skipped. Admission commits before the
  request, and no transaction stays open across it. Hiding or deleting the
  content after admission does not recall the request.

  The cooldown written at admission stays if the scan crashes during the
  request, so the next scan moves past that row. Both outcomes are guarded by
  the token read, to the microsecond, and a missing vector:

      update tip_search set embedding = $3
      where tip_id = $1 and embedding is null and text_at = $2

      update tip_search set embed_after = clock_timestamp() + interval '10 minutes'
      where tip_id = $1 and embedding is null and text_at = $2

  Reviews use `review_search` and `review_id`. A text change during the
  request advances the token and clears the cooldown, so neither update
  applies, and a later scan embeds the new text. Every classified failure
  restarts the cooldown and the scan continues with the next row. Each
  admitted row is attempted once per scan. Unexpected errors fail the scan.

  At 30 seconds per request, one scan can take 25 minutes plus database time.
  Each scan returns its counts:

      %{
        selected: candidates read,
        skipped: candidates that failed admission,
        embedded: vectors stored,
        stale: vectors discarded because the row changed during the request,
        failed: %{EmbeddingProvider.error() => count}
      }

  ## Changing the model

  Never mix vectors from two models. To change the embedding model or
  runtime, with the release run by Docker Compose:

  1. Stop every instance of the old release, so no scan or query uses the old
     model: `docker compose stop app`.
  2. Clear the vectors without starting the application or calling a provider:

         docker compose run --rm app bin/tips eval "Tips.Release.clear_embeddings()"

     It calls `clear_all/0`: in one transaction, every tip and review vector
     and cooldown is cleared and every token is advanced, including rows that
     are hidden or deleted. A write from a request started before the clear
     then fails its guard. That is extra protection; it does not replace
     step 1.
  3. Build the release with the new model for both documents and queries.
  4. Start it: `docker compose up -d app`. Scans embed every live document
     again.
  """

  alias Tips.Content.Search.EmbeddingProvider
  alias Tips.Repo

  @limit 50
  @cooldown "clock_timestamp() + interval '10 minutes'"
  @due "s.embedding IS NULL AND (s.embed_after IS NULL OR s.embed_after < clock_timestamp())"
  @live_tip "t.deleted_at IS NULL AND t.dead_at IS NULL"
  @live_review "r.deleted_at IS NULL AND r.dead_at IS NULL"

  @type summary :: %{
          selected: non_neg_integer(),
          skipped: non_neg_integer(),
          embedded: non_neg_integer(),
          stale: non_neg_integer(),
          failed: %{EmbeddingProvider.error() => pos_integer()}
        }

  @doc """
  Runs one bounded scan. See "Scanning".

  `opts` are passed to `EmbeddingProvider.client!/1`.
  """
  @spec scan(keyword()) :: summary()
  def scan(opts \\ []) do
    case candidates() do
      [] ->
        summary(0)

      candidates ->
        client = EmbeddingProvider.client!(opts)
        Enum.reduce(candidates, summary(length(candidates)), &attempt(&1, client, &2))
    end
  end

  @doc """
  Clears every vector and cooldown and advances every token, in one
  transaction. Run only with the old release stopped; see "Changing the model".
  """
  @spec clear_all() :: {:ok, %{tips: non_neg_integer(), reviews: non_neg_integer()}}
  def clear_all do
    Repo.transact(fn ->
      cleared =
        Map.new([tips: "tip_search", reviews: "review_search"], fn {key, table} ->
          %{num_rows: rows} =
            Repo.maintenance_query!("""
            UPDATE #{table}
            SET embedding = NULL, embed_after = NULL,
                text_at = greatest(clock_timestamp(), text_at + interval '1 microsecond')
            """)

          {key, rows}
        end)

      {:ok, cleared}
    end)
  end

  defp candidates do
    tips =
      select("""
      SELECT s.tip_id, s.text_at FROM tip_search s
      JOIN tips t ON t.id = s.tip_id AND #{@live_tip}
      WHERE #{@due}
      ORDER BY s.tip_id
      LIMIT #{@limit}
      """)

    reviews =
      select("""
      SELECT s.review_id, s.text_at FROM review_search s
      JOIN reviews r ON r.id = s.review_id AND #{@live_review}
      JOIN tips t ON t.id = r.tip_id AND #{@live_tip}
      WHERE #{@due}
      ORDER BY s.review_id
      LIMIT #{@limit}
      """)

    tips
    |> Enum.map(fn [id, token] -> {:tip, id, token} end)
    |> alternate(Enum.map(reviews, fn [id, token] -> {:review, id, token} end))
    |> Enum.take(@limit)
  end

  defp select(sql), do: Repo.query!(sql).rows

  defp alternate([tip | tips], [review | reviews]), do: [tip, review | alternate(tips, reviews)]
  defp alternate(tips, []), do: tips
  defp alternate([], reviews), do: reviews

  defp attempt({kind, id, token}, client, summary) do
    case admit(kind, id, token) do
      nil -> count(summary, :skipped)
      text -> client |> EmbeddingProvider.embed_document(text) |> finish(kind, id, token, summary)
    end
  end

  defp finish({:ok, vector}, kind, id, token, summary) do
    %{num_rows: rows} =
      Repo.query!(
        "UPDATE #{table(kind)} SET embedding = $3::text::vector(1024) " <>
          "WHERE #{id_column(kind)} = $1 AND embedding IS NULL AND text_at = $2",
        [id, token, vector]
      )

    count(summary, if(rows == 1, do: :embedded, else: :stale))
  end

  defp finish({:error, reason}, kind, id, token, summary) do
    Repo.query!(
      "UPDATE #{table(kind)} SET embed_after = #{@cooldown} " <>
        "WHERE #{id_column(kind)} = $1 AND embedding IS NULL AND text_at = $2",
      [id, token]
    )

    update_in(summary, [:failed, reason], &((&1 || 0) + 1))
  end

  defp admit(:tip, id, token) do
    claim(
      """
      UPDATE tip_search s SET embed_after = #{@cooldown}
      FROM tips t
      WHERE s.tip_id = $1 AND t.id = s.tip_id AND #{@live_tip}
      """,
      id,
      token
    )
  end

  defp admit(:review, id, token) do
    claim(
      """
      UPDATE review_search s SET embed_after = #{@cooldown}
      FROM reviews r JOIN tips t ON t.id = r.tip_id AND #{@live_tip}
      WHERE s.review_id = $1 AND r.id = s.review_id AND #{@live_review}
      """,
      id,
      token
    )
  end

  defp claim(update, id, token) do
    sql = update <> " AND s.text_at = $2 AND #{@due} RETURNING s.search_text"

    case Repo.query!(sql, [id, token]) do
      %{rows: [[text]]} -> text
      %{rows: []} -> nil
    end
  end

  defp summary(selected),
    do: %{selected: selected, skipped: 0, embedded: 0, stale: 0, failed: %{}}

  defp count(summary, key), do: Map.update!(summary, key, &(&1 + 1))

  defp table(:tip), do: "tip_search"
  defp table(:review), do: "review_search"

  defp id_column(:tip), do: "tip_id"
  defp id_column(:review), do: "review_id"
end
