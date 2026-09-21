defmodule Tips.Content.SearchSchemaTest do
  use Tips.DataCase, async: true

  alias Tips.Content.Search

  import Tips.ContentFixtures
  import Tips.AccountsFixtures

  test "migration installs both index families on the pinned image" do
    assert %{rows: indexes} =
             Repo.query!(
               """
               SELECT indexname, indexdef
               FROM pg_indexes
               WHERE schemaname = 'public'
                 AND indexname = ANY($1)
               ORDER BY indexname
               """,
               [
                 [
                   "review_search_queue",
                   "reviews_bm25",
                   "reviews_embedding",
                   "tip_search_queue",
                   "tips_bm25",
                   "tips_embedding"
                 ]
               ]
             )

    assert indexes == [
             [
               "review_search_queue",
               "CREATE INDEX review_search_queue ON public.review_search USING btree (review_id) WHERE (embedding IS NULL)"
             ],
             [
               "reviews_bm25",
               "CREATE INDEX reviews_bm25 ON public.review_search USING bm25 (search_text) WITH (text_config=english)"
             ],
             [
               "reviews_embedding",
               "CREATE INDEX reviews_embedding ON public.review_search USING hnsw (embedding vector_cosine_ops)"
             ],
             [
               "tip_search_queue",
               "CREATE INDEX tip_search_queue ON public.tip_search USING btree (tip_id) WHERE (embedding IS NULL)"
             ],
             [
               "tips_bm25",
               "CREATE INDEX tips_bm25 ON public.tip_search USING bm25 (search_text) WITH (text_config=english)"
             ],
             [
               "tips_embedding",
               "CREATE INDEX tips_embedding ON public.tip_search USING hnsw (embedding vector_cosine_ops)"
             ]
           ]
  end

  for kind <- [:tip, :review] do
    test "#{kind} search rows reference their content" do
      kind = unquote(kind)
      id = content_id(kind)
      assert %{num_rows: 1} = insert_search(kind, id, "searchable text")

      error =
        assert_raise Postgrex.Error, fn ->
          insert_search(kind, -1, "orphaned text")
        end

      assert %{code: :foreign_key_violation} = error.postgres
    end

    test "#{kind} search rows reject duplicate content keys" do
      kind = unquote(kind)
      id = content_id(kind)
      insert_search(kind, id, "first text")

      error =
        assert_raise Postgrex.Error, fn ->
          insert_search(kind, id, "duplicate text")
        end

      assert %{code: :unique_violation} = error.postgres
    end

    test "#{kind} search rows require a content key" do
      kind = unquote(kind)

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("INSERT INTO #{search_table(kind)} (search_text) VALUES ('text')")
        end

      assert %{code: :not_null_violation} = error.postgres
    end

    test "#{kind} search rows require search text" do
      kind = unquote(kind)
      id = content_id(kind)

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("INSERT INTO #{search_table(kind)} (#{id_column(kind)}) VALUES ($1)", [
            id
          ])
        end

      assert %{code: :not_null_violation} = error.postgres
    end

    test "#{kind} search rows require a freshness token" do
      kind = unquote(kind)
      id = content_id(kind)

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            "INSERT INTO #{search_table(kind)} (#{id_column(kind)}, search_text, text_at) VALUES ($1, 'text', NULL)",
            [id]
          )
        end

      assert %{code: :not_null_violation} = error.postgres
    end

    test "#{kind} search rows default the freshness token" do
      kind = unquote(kind)
      id = content_id(kind)

      assert %{rows: [[%DateTime{}]]} =
               Repo.query!(
                 "INSERT INTO #{search_table(kind)} (#{id_column(kind)}, search_text) VALUES ($1, 'text') RETURNING text_at",
                 [id]
               )
    end
  end

  for kind <- [:tip, :review] do
    test "wrong vector dimension fails for #{kind} search" do
      kind = unquote(kind)
      id = content_id(kind)

      error =
        assert_raise Postgrex.Error, fn ->
          insert_search(kind, id, "wrong vector", "[1,0,0]")
        end

      assert %{code: :data_exception, message: message} = error.postgres
      assert message =~ "1024 dimensions"
    end
  end

  test "1024-dimensional vectors store on both search tables" do
    for kind <- [:tip, :review] do
      id = content_id(kind)
      insert_search(kind, id, "right vector", unit_vector(0))

      assert %{rows: [[1024]]} =
               Repo.query!(
                 "SELECT vector_dims(embedding) FROM #{search_table(kind)} WHERE #{id_column(kind)} = $1",
                 [id]
               )
    end
  end

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

  test "queue indexes do not enforce parent visibility" do
    now = DateTime.utc_now(:second)
    future = DateTime.add(now, 3_600, :second)
    live_tip = tip_fixture()
    cooling_tip = tip_fixture()
    deleted_tip = tip_fixture(user_fixture(), %{deleted_at: now})
    hidden_tip = tip_fixture(user_fixture(), %{dead_at: now})

    live_review = review_fixture(live_tip)
    cooling_review = review_fixture(cooling_tip)
    deleted_review = review_fixture(tip_fixture(), %{deleted_at: now})
    hidden_review = review_fixture(tip_fixture(), %{dead_at: now})
    deleted_parent_review = review_fixture(deleted_tip)
    hidden_parent_review = review_fixture(hidden_tip)

    for tip <- [live_tip, deleted_tip, hidden_tip] do
      insert_search(:tip, tip.id, "tip queue")
    end

    insert_search(:tip, cooling_tip.id, "cooling tip", nil, future)

    for review <- [
          live_review,
          deleted_review,
          hidden_review,
          deleted_parent_review,
          hidden_parent_review
        ] do
      insert_search(:review, review.id, "review queue")
    end

    insert_search(:review, cooling_review.id, "cooling review", nil, future)

    assert queue_ids(:tip) ==
             Enum.sort([live_tip.id, cooling_tip.id, deleted_tip.id, hidden_tip.id])

    assert eligible_queue_ids(:tip) == [live_tip.id]

    assert queue_ids(:review) ==
             Enum.sort([
               live_review.id,
               cooling_review.id,
               deleted_review.id,
               hidden_review.id,
               deleted_parent_review.id,
               hidden_parent_review.id
             ])

    assert eligible_queue_ids(:review) == [live_review.id]
  end

  for kind <- [:tip, :review] do
    test "#{kind} writer sets text and freshness, clears vector and cooldown" do
      kind = unquote(kind)
      id = content_id(kind)

      assert {:ok, {first_token, second_token}} =
               Repo.transact(fn ->
                 assert :ok = write_text(kind, id, "first text")
                 first_token = search_token(kind, id)
                 assert :ok = write_text(kind, id, "second text")
                 {:ok, {first_token, search_token(kind, id)}}
               end)

      assert DateTime.compare(second_token, first_token) == :gt

      assert %{rows: [[^second_token]]} =
               Repo.query!(
                 """
                 UPDATE #{search_table(kind)}
                 SET embedding = $2::text::vector(1024), embed_after = clock_timestamp() + interval '1 hour'
                 WHERE #{id_column(kind)} = $1
                 RETURNING text_at
                 """,
                 [id, unit_vector(0)]
               )

      assert {:ok, :written} =
               Repo.transact(fn ->
                 assert :ok = write_text(kind, id, "third text")
                 {:ok, :written}
               end)

      assert %{rows: [["third text", third_token, true, nil]]} =
               search_row(kind, id)

      assert DateTime.compare(third_token, second_token) == :gt
    end

    test "#{kind} caller rollback restores search rows" do
      kind = unquote(kind)
      id = content_id(kind)

      assert {:error, :caller_failed} =
               Repo.transact(fn ->
                 write_text(kind, id, "rolled-back insert")
                 {:error, :caller_failed}
               end)

      assert %{rows: []} = search_row(kind, id)

      assert {:ok, :written} =
               Repo.transact(fn ->
                 write_text(kind, id, "committed text")
                 {:ok, :written}
               end)

      assert {:error, :caller_failed} =
               Repo.transact(fn ->
                 write_text(kind, id, "rolled-back text")
                 {:error, :caller_failed}
               end)

      assert %{rows: [["committed text", _token, true, nil]]} = search_row(kind, id)
    end

    test "#{kind} freshness advances when the previous token is ahead of wall time" do
      kind = unquote(kind)
      id = content_id(kind)

      assert %{rows: [[future_token]]} =
               Repo.query!(
                 """
                 INSERT INTO #{search_table(kind)}
                   (#{id_column(kind)}, search_text, text_at)
                 VALUES ($1, 'future text', clock_timestamp() + interval '1 day')
                 RETURNING text_at
                 """,
                 [id]
               )

      assert {:ok, :written} =
               Repo.transact(fn ->
                 write_text(kind, id, "new text")
                 {:ok, :written}
               end)

      assert %{rows: [["new text", new_token, true, nil]]} = search_row(kind, id)
      assert DateTime.diff(new_token, future_token, :microsecond) >= 1
    end

    test "#{kind} stale success and failure cannot change rewritten search rows" do
      kind = unquote(kind)
      id = content_id(kind)

      assert {:ok, old_token} =
               Repo.transact(fn ->
                 write_text(kind, id, "old text")
                 {:ok, search_token(kind, id)}
               end)

      assert {:ok, :written} =
               Repo.transact(fn ->
                 write_text(kind, id, "current text")
                 {:ok, :written}
               end)

      assert %{num_rows: 0} = stale_success(kind, id, old_token)
      assert %{num_rows: 0} = stale_failure(kind, id, old_token)

      current_token = search_token(kind, id)
      assert %{num_rows: 1} = stale_failure(kind, id, current_token)

      assert %{rows: [["current text", ^current_token, true, %DateTime{}]]} =
               search_row(kind, id)

      assert %{num_rows: 1} = stale_success(kind, id, current_token)

      assert %{rows: [["current text", ^current_token, false, %DateTime{}]]} =
               search_row(kind, id)
    end
  end

  test "writers reject calls outside a caller transaction" do
    tip = tip_fixture()
    review = review_fixture(tip)

    assert_raise ArgumentError, ~r/caller transaction/, fn ->
      Search.write_tip_text(tip.id, "tip text")
    end

    assert_raise ArgumentError, ~r/caller transaction/, fn ->
      Search.write_review_text(review.id, "review text")
    end
  end

  test "content counter updates leave search rows unchanged" do
    tip = tip_fixture()
    review = review_fixture(tip)

    assert {:ok, :written} =
             Repo.transact(fn ->
               Search.write_tip_text(tip.id, "tip text")
               Search.write_review_text(review.id, "review text")
               {:ok, :written}
             end)

    before_tip = search_row(:tip, tip.id)
    before_review = search_row(:review, review.id)

    Repo.query!("UPDATE tips SET up_count = up_count + 1 WHERE id = $1", [tip.id])
    Repo.query!("UPDATE reviews SET down_count = down_count + 1 WHERE id = $1", [review.id])

    assert search_row(:tip, tip.id) == before_tip
    assert search_row(:review, review.id) == before_review
  end

  defp content_id(:tip), do: tip_fixture().id
  defp content_id(:review), do: review_fixture().id

  defp search_table(:tip), do: "tip_search"
  defp search_table(:review), do: "review_search"

  defp id_column(:tip), do: "tip_id"
  defp id_column(:review), do: "review_id"

  defp index_name(:tip, :bm25), do: "tips_bm25"
  defp index_name(:review, :bm25), do: "reviews_bm25"

  defp insert_search(kind, id, text, embedding \\ nil, embed_after \\ nil) do
    Repo.query!(
      """
      INSERT INTO #{search_table(kind)}
        (#{id_column(kind)}, search_text, embedding, embed_after)
      VALUES ($1, $2, $3::text::vector(1024), $4)
      """,
      [id, text, embedding, embed_after]
    )
  end

  defp write_text(:tip, id, text), do: Search.write_tip_text(id, text)
  defp write_text(:review, id, text), do: Search.write_review_text(id, text)

  defp search_row(kind, id) do
    Repo.query!(
      """
      SELECT search_text, text_at, embedding IS NULL, embed_after
      FROM #{search_table(kind)}
      WHERE #{id_column(kind)} = $1
      """,
      [id]
    )
  end

  defp search_token(kind, id) do
    assert %{rows: [[token]]} =
             Repo.query!(
               "SELECT text_at FROM #{search_table(kind)} WHERE #{id_column(kind)} = $1",
               [id]
             )

    token
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

  defp queue_ids(kind) do
    Repo.query!("""
    SELECT #{id_column(kind)}
    FROM #{search_table(kind)}
    WHERE embedding IS NULL
    ORDER BY #{id_column(kind)}
    """).rows
    |> List.flatten()
  end

  defp eligible_queue_ids(:tip) do
    Repo.query!("""
    SELECT s.tip_id
    FROM tip_search s
    JOIN live_tips t ON t.id = s.tip_id
    WHERE s.embedding IS NULL
      AND (s.embed_after IS NULL OR s.embed_after < clock_timestamp())
    ORDER BY s.tip_id
    """).rows
    |> List.flatten()
  end

  defp eligible_queue_ids(:review) do
    Repo.query!("""
    SELECT s.review_id
    FROM review_search s
    JOIN live_reviews r ON r.id = s.review_id
    JOIN live_tips t ON t.id = r.tip_id
    WHERE s.embedding IS NULL
      AND (s.embed_after IS NULL OR s.embed_after < clock_timestamp())
    ORDER BY s.review_id
    """).rows
    |> List.flatten()
  end

  defp stale_success(kind, id, old_token) do
    Repo.query!(
      """
      UPDATE #{search_table(kind)}
      SET embedding = $2::text::vector(1024)
      WHERE #{id_column(kind)} = $1 AND embedding IS NULL AND text_at = $3
      """,
      [id, unit_vector(0), old_token]
    )
  end

  defp stale_failure(kind, id, old_token) do
    Repo.query!(
      """
      UPDATE #{search_table(kind)}
      SET embed_after = clock_timestamp() + interval '10 minutes'
      WHERE #{id_column(kind)} = $1 AND embedding IS NULL AND text_at = $2
      """,
      [id, old_token]
    )
  end

  defp unit_vector(position) do
    values = for index <- 0..1023, do: if(index == position, do: 1, else: 0)
    "[#{Enum.join(values, ",")}]"
  end

  defp nearby_vector do
    "[#{Enum.join([0.8, 0.2 | List.duplicate(0, 1022)], ",")}]"
  end
end
