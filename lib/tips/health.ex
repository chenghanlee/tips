defmodule Tips.Health do
  @moduledoc "Checks whether the application can reach its database."

  @deadline 1_000

  @spec check() :: :ok | :error
  def check do
    repo = Tips.Repo.get_dynamic_repo()

    task =
      Task.async(fn ->
        Tips.Repo.put_dynamic_repo(repo)
        probe()
      end)

    case Task.yield(task, @deadline) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> :error
    end
  end

  defp probe do
    case Tips.Repo.query("SELECT 1", [], timeout: @deadline) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :error
    end
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end
end
