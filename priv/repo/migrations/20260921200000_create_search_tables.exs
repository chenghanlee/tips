defmodule Tips.Repo.Migrations.CreateSearchTables do
  use Ecto.Migration

  def change do
    create table(:tip_search, primary_key: false) do
      add :tip_id, references(:tips, type: :bigint, on_delete: :nothing), primary_key: true
      add :search_text, :text, null: false
      add :text_at, :timestamptz, null: false, default: fragment("now()")
      add :embedding, :"vector(1024)"
      add :embed_after, :timestamptz
    end

    create table(:review_search, primary_key: false) do
      add :review_id, references(:reviews, type: :bigint, on_delete: :nothing), primary_key: true
      add :search_text, :text, null: false
      add :text_at, :timestamptz, null: false, default: fragment("now()")
      add :embedding, :"vector(1024)"
      add :embed_after, :timestamptz
    end

    execute """
            CREATE INDEX tips_bm25
            ON tip_search USING bm25 (search_text) WITH (text_config = 'english')
            """,
            "DROP INDEX tips_bm25"

    execute """
            CREATE INDEX reviews_bm25
            ON review_search USING bm25 (search_text) WITH (text_config = 'english')
            """,
            "DROP INDEX reviews_bm25"

    execute """
            CREATE INDEX tips_embedding
            ON tip_search USING hnsw (embedding vector_cosine_ops)
            """,
            "DROP INDEX tips_embedding"

    execute """
            CREATE INDEX reviews_embedding
            ON review_search USING hnsw (embedding vector_cosine_ops)
            """,
            "DROP INDEX reviews_embedding"

    execute """
            CREATE INDEX tip_search_queue
            ON tip_search (tip_id) WHERE embedding IS NULL
            """,
            "DROP INDEX tip_search_queue"

    execute """
            CREATE INDEX review_search_queue
            ON review_search (review_id) WHERE embedding IS NULL
            """,
            "DROP INDEX review_search_queue"
  end
end
