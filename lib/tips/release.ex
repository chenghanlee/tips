defmodule Tips.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :tips

  alias Tips.Content.Search.Embeddings

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Clears every search vector for an embedding model or runtime change.

  Run only after every instance of the old release has stopped. See
  "Changing the model" in `Tips.Content.Search.Embeddings`.
  """
  def clear_embeddings do
    load_app()

    {:ok, {:ok, cleared}, _} =
      Ecto.Migrator.with_repo(Tips.Repo, fn _repo -> Embeddings.clear_all() end)

    cleared
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
