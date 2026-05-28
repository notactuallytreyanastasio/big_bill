defmodule BigBill.Repo.Migrations.AddSearchEmbeddings do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS vector")

    execute("""
    CREATE TABLE search_embeddings (
      id BIGSERIAL PRIMARY KEY,
      source_type VARCHAR NOT NULL,
      source_id VARCHAR NOT NULL,
      title VARCHAR,
      content TEXT NOT NULL,
      embedding vector(384),
      metadata JSONB DEFAULT '{}',
      inserted_at TIMESTAMP DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX ON search_embeddings
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 20)
    """)

    execute("CREATE INDEX ON search_embeddings (source_type)")
    execute("CREATE UNIQUE INDEX ON search_embeddings (source_type, source_id)")
  end

  def down do
    execute("DROP TABLE IF EXISTS search_embeddings")
    execute("DROP EXTENSION IF EXISTS vector")
  end
end
