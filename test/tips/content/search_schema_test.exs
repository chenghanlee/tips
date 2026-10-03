defmodule Tips.Content.SearchSchemaTest do
  use Tips.DataCase, async: true

  import Tips.ContentFixtures

  test "BM25 and cosine queries run on the side tables" do
    postgresql_tip = tip_fixture()
    bread_tip = tip_fixture()
    postgresql_review = review_fixture(postgresql_tip)
    bread_review = review_fixture(bread_tip)

    insert_search(:tip, postgresql_tip.id, "PostgreSQL database search", unit_vector(0))
    insert_search(:tip, bread_tip.id, "Baking sourdough bread", unit_vector(1))

    insert_search(
      :review,
      postgresql_review.id,
      "PostgreSQL vector index",
      nearby_vector()
    )

    insert_search(:review, bread_review.id, "Sourdough starter", unit_vector(1))

    assert_bm25_scores(:tip, postgresql_tip.id, bread_tip.id)
    assert_bm25_scores(:review, postgresql_review.id, bread_review.id)

    Repo.query!("SET LOCAL enable_seqscan = off")
    Repo.query!("SET LOCAL hnsw.iterative_scan = relaxed_order")

    assert plan_uses_index?(bm25_plan(:tip), "tips_bm25")
    assert plan_uses_index?(bm25_plan(:review), "reviews_bm25")
    assert plan_uses_index?(cosine_plan(:tip, unit_vector(0)), "tips_embedding")
    assert plan_uses_index?(cosine_plan(:review, unit_vector(0)), "reviews_embedding")

    assert bm25_ids(:tip) == [postgresql_tip.id]
    assert bm25_ids(:review) == [postgresql_review.id]
    assert cosine_ids(:tip, unit_vector(0)) == [postgresql_tip.id, bread_tip.id]
    assert cosine_ids(:review, unit_vector(0)) == [postgresql_review.id, bread_review.id]
  end

  defp search_table(:tip), do: "tip_search"
  defp search_table(:review), do: "review_search"

  defp id_column(:tip), do: "tip_id"
  defp id_column(:review), do: "review_id"

  defp index_name(:tip, :bm25), do: "tips_bm25"
  defp index_name(:review, :bm25), do: "reviews_bm25"

  defp insert_search(kind, id, text, embedding) do
    Repo.query!(
      """
      INSERT INTO #{search_table(kind)}
        (#{id_column(kind)}, search_text, embedding)
      VALUES ($1, $2, $3::text::vector(1024))
      """,
      [id, text, embedding]
    )
  end

  defp assert_bm25_scores(kind, matching_id, other_id) do
    assert %{rows: [[^matching_id, matching_score], [^other_id, other_score]]} =
             Repo.query!("""
             SELECT #{id_column(kind)},
                    search_text <@> to_bm25query('postgresql', '#{index_name(kind, :bm25)}')
             FROM #{search_table(kind)}
             ORDER BY #{id_column(kind)}
             """)

    assert matching_score < 0
    assert other_score >= 0
  end

  defp bm25_ids(kind) do
    Repo.query!("""
    SELECT #{id_column(kind)}
    FROM (
      SELECT #{id_column(kind)},
             search_text <@> to_bm25query('postgresql', '#{index_name(kind, :bm25)}') AS distance
      FROM #{search_table(kind)}
      ORDER BY distance
      LIMIT 5
    ) candidates
    WHERE distance < 0
    ORDER BY distance, #{id_column(kind)}
    """).rows
    |> List.flatten()
  end

  defp cosine_ids(kind, vector) do
    Repo.query!(
      """
      WITH candidates AS MATERIALIZED (
        SELECT #{id_column(kind)}, embedding <=> $1::text::vector(1024) AS distance
        FROM #{search_table(kind)}
        ORDER BY embedding <=> $1::text::vector(1024)
        LIMIT 5
      )
      SELECT #{id_column(kind)} FROM candidates
      ORDER BY distance + 0, #{id_column(kind)}
      """,
      [vector]
    ).rows
    |> List.flatten()
  end

  defp bm25_plan(kind) do
    explain("""
    SELECT #{id_column(kind)}
    FROM #{search_table(kind)}
    ORDER BY search_text <@> to_bm25query('postgresql', '#{index_name(kind, :bm25)}')
    LIMIT 2
    """)
  end

  defp cosine_plan(kind, vector) do
    explain(
      """
      SELECT #{id_column(kind)}
      FROM #{search_table(kind)}
      ORDER BY embedding <=> $1::text::vector(1024)
      LIMIT 2
      """,
      [vector]
    )
  end

  defp explain(sql, params \\ []) do
    assert %{rows: [[plan]]} = Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params)
    plan
  end

  defp plan_uses_index?(%{"Index Name" => name}, name), do: true

  defp plan_uses_index?(map, name) when is_map(map) do
    Enum.any?(map, fn {_key, value} -> plan_uses_index?(value, name) end)
  end

  defp plan_uses_index?(list, name) when is_list(list) do
    Enum.any?(list, &plan_uses_index?(&1, name))
  end

  defp plan_uses_index?(_value, _name), do: false

  defp unit_vector(position) do
    values = for index <- 0..1023, do: if(index == position, do: 1, else: 0)
    "[#{Enum.join(values, ",")}]"
  end

  defp nearby_vector do
    "[#{Enum.join([0.8, 0.2 | List.duplicate(0, 1022)], ",")}]"
  end
end
