defmodule Tips.Repo.Migrations.CreateExtensions do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector")

    execute(
      "CREATE EXTENSION IF NOT EXISTS pg_textsearch",
      "DROP EXTENSION IF EXISTS pg_textsearch"
    )
  end
end
