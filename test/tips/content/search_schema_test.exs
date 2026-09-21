defmodule Tips.Content.SearchSchemaTest do
  use Tips.DataCase, async: true

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

    assert [
             ["review_search_queue", review_queue],
             ["reviews_bm25", reviews_bm25],
             ["reviews_embedding", reviews_embedding],
             ["tip_search_queue", tip_queue],
             ["tips_bm25", tips_bm25],
             ["tips_embedding", tips_embedding]
           ] = indexes

    assert reviews_bm25 =~ "USING bm25 (search_text)"
    assert tips_bm25 =~ "USING bm25 (search_text)"
    assert reviews_embedding =~ "USING hnsw (embedding vector_cosine_ops)"
    assert tips_embedding =~ "USING hnsw (embedding vector_cosine_ops)"
    assert review_queue =~ "(review_id) WHERE (embedding IS NULL)"
    assert tip_queue =~ "(tip_id) WHERE (embedding IS NULL)"
  end
end
