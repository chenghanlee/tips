defmodule Tips.Health do
  @moduledoc "Checks whether the application can reach its database."

  @spec check() :: :ok | :error
  def check do
    case Tips.Repo.query("SELECT 1", [], timeout: 1_000) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :error
    end
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end
end
