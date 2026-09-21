defmodule Tips.FeatureCase do
  @moduledoc """
  Browser tests with a per-test SQL sandbox and isolated Chrome session.

  Wallaby.Feature checks out the Repo and sends Phoenix.Ecto.SQL.Sandbox.metadata_for/2
  metadata in the browser's user agent for HTTP and LiveView sandbox allowances.
  """

  use ExUnit.CaseTemplate

  setup do
    {:ok, _} = Application.ensure_all_started(:wallaby)
    :ok
  end

  using do
    quote do
      use Wallaby.Feature
      import Wallaby.Query
    end
  end
end
