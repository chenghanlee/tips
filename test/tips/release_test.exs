defmodule Tips.ReleaseTest do
  # Migrator needs separate connections, outside a sandbox transaction.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox

  test "release migration is idempotent and preserves the request timeout" do
    Sandbox.mode(Tips.Repo, :auto)
    on_exit(fn -> Sandbox.mode(Tips.Repo, :manual) end)

    versions = Ecto.Migrator.migrated_versions(Tips.Repo)
    assert versions != []
    assert [{:ok, [], _}] = Tips.Release.migrate()
    assert [{:ok, [], _}] = Tips.Release.migrate()
    assert Ecto.Migrator.migrated_versions(Tips.Repo) == versions
    assert Tips.Repo.config()[:timeout] == 2_000
  end
end
