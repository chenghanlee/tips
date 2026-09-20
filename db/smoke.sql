\set ON_ERROR_STOP on
CREATE EXTENSION vector;
CREATE EXTENSION pg_textsearch;

SELECT extname, extversion FROM pg_extension
WHERE extname IN ('vector', 'pg_textsearch') ORDER BY extname;
DO $$
BEGIN
  IF current_setting('server_version_num')::int <> 180006 THEN
    RAISE EXCEPTION 'Expected PostgreSQL 18.6, got %', version();
  END IF;
  IF (SELECT extversion FROM pg_extension WHERE extname = 'vector') IS DISTINCT FROM '0.8.6'
     OR (SELECT extversion FROM pg_extension WHERE extname = 'pg_textsearch') IS DISTINCT FROM '1.4.0' THEN
    RAISE EXCEPTION 'Unexpected extension versions';
  END IF;
END $$;

CREATE TABLE smoke_documents (id integer PRIMARY KEY, search_text text, embedding vector(1024));
INSERT INTO smoke_documents VALUES
  (1, 'PostgreSQL database search', (ARRAY[1.0, 0.0] || array_fill(0.0, ARRAY[1022]))::vector),
  (2, 'PostgreSQL vector index', (ARRAY[0.8, 0.2] || array_fill(0.0, ARRAY[1022]))::vector),
  (3, 'Baking sourdough bread', (ARRAY[0.0, 1.0] || array_fill(0.0, ARRAY[1022]))::vector);
CREATE INDEX smoke_bm25 ON smoke_documents USING bm25 (search_text) WITH (text_config = 'english');
CREATE INDEX smoke_hnsw ON smoke_documents USING hnsw (embedding vector_cosine_ops);
ANALYZE smoke_documents;
SET hnsw.iterative_scan = relaxed_order;
SET enable_seqscan = off;

DO $$
DECLARE
  hits integer;
  ids integer[];
  bm25_sql text := $query$
    SELECT id, search_text <@> to_bm25query('postgresql', 'smoke_bm25') AS d
    FROM smoke_documents ORDER BY d LIMIT 5
  $query$;
  vector_sql text := $query$
    SELECT id, embedding <=> (ARRAY[1.0, 0.0] || array_fill(0.0, ARRAY[1022]))::vector(1024) AS d
    FROM smoke_documents ORDER BY d LIMIT 2
  $query$;
  plan_line text;
  plan_text text;
  query_text text;
  index_name text;
BEGIN
  EXECUTE 'SELECT count(*) FROM (' || bm25_sql || ') candidates WHERE d < 0' INTO hits;
  IF hits <> 2 THEN
    RAISE EXCEPTION 'Expected 2 BM25 matches, got %', hits;
  END IF;
  RAISE NOTICE 'BM25 negative-score matches: %', hits;

  -- Materialize and re-sort relaxed HNSW results, as in the application query.
  EXECUTE 'WITH candidates AS MATERIALIZED (' || vector_sql || ')
    SELECT array_agg(id ORDER BY d + 0, id) FROM candidates' INTO ids;
  IF ids IS DISTINCT FROM ARRAY[1, 2] THEN
    RAISE EXCEPTION 'Expected vector neighbors {1,2}, got %', ids;
  END IF;
  RAISE NOTICE '1024-dimension cosine neighbors: %', ids;

  SELECT count(*) INTO hits FROM (
    SELECT search_text <@> to_bm25query('quasarxyznonmatch', 'smoke_bm25') AS d
    FROM smoke_documents ORDER BY d LIMIT 5
  ) candidates WHERE d < 0;
  IF hits <> 0 THEN
    RAISE EXCEPTION 'Expected 0 BM25 nonmatches, got %', hits;
  END IF;
  RAISE NOTICE 'Zero-match BM25 matches: %', hits;

  FOR query_text, index_name IN
    SELECT * FROM (VALUES (bm25_sql, 'smoke_bm25'), (vector_sql, 'smoke_hnsw')) AS checks(sql, name)
  LOOP
    plan_text := '';
    FOR plan_line IN EXECUTE 'EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) ' || query_text LOOP
      RAISE NOTICE '%', plan_line;
      plan_text := plan_text || plan_line || E'\n';
    END LOOP;
    IF position(index_name IN plan_text) = 0 THEN
      RAISE EXCEPTION 'Expected index % in plan: %', index_name, plan_text;
    END IF;
  END LOOP;
END $$;
\echo 'Database extension smoke passed'
