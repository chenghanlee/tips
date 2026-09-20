defmodule Tips.RepoExtensionsTest do
  use Tips.DataCase, async: true

  test "fresh migrations install the pinned extensions" do
    assert Repo.query!("SHOW server_version_num").rows == [["180006"]]

    assert Repo.query!("""
           SELECT extname, extversion FROM pg_extension
           WHERE extname IN ('vector', 'pg_textsearch') ORDER BY extname
           """).rows == [["pg_textsearch", "1.4.0"], ["vector", "0.8.6"]]
  end

  test "migrated database executes 1024-dimension cosine and BM25 queries" do
    Repo.query!("""
    CREATE TEMP TABLE documents (id integer PRIMARY KEY, search_text text, embedding vector(1024))
    """)

    Repo.query!("""
    INSERT INTO documents VALUES
      (1, 'PostgreSQL database search', (ARRAY[1.0, 0.0] || array_fill(0.0, ARRAY[1022]))::vector),
      (2, 'PostgreSQL vector index', (ARRAY[0.8, 0.2] || array_fill(0.0, ARRAY[1022]))::vector),
      (3, 'Baking sourdough bread', (ARRAY[0.0, 1.0] || array_fill(0.0, ARRAY[1022]))::vector)
    """)

    Repo.query!("""
    CREATE INDEX documents_bm25 ON documents USING bm25 (search_text) WITH (text_config = 'english')
    """)

    assert Repo.query!("""
           SELECT id FROM documents
           ORDER BY embedding <=> (ARRAY[1.0, 0.0] || array_fill(0.0, ARRAY[1022]))::vector(1024)
           LIMIT 2
           """).rows == [[1], [2]]

    assert Repo.query!("""
           SELECT id FROM (
             SELECT id, search_text <@> to_bm25query('postgresql', 'documents_bm25') AS distance
             FROM documents ORDER BY distance LIMIT 5
           ) candidates WHERE distance < 0 ORDER BY id
           """).rows == [[1], [2]]
  end
end
