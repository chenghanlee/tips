defmodule Tips.ObanConfigTest do
  use ExUnit.Case, async: true

  alias Tips.Workers.ExpireRegistrations

  test "registration expiry runs every minute on the maintenance queue" do
    # Tests run Oban in manual mode, which starts no plugins; build the config as other
    # environments do. `Oban.Config.new/1` also validates the crontab.
    config = Keyword.put(Application.fetch_env!(:tips, Oban), :testing, :disabled)

    assert %Oban.Config{plugins: plugins} = Oban.Config.new(config)

    assert {Oban.Cron, crontab: [{"* * * * *", ExpireRegistrations}]} =
             List.keyfind(plugins, Oban.Cron, 0)

    assert {Oban.Pruner, max_age: {7, :days}} = List.keyfind(plugins, Oban.Pruner, 0)

    assert %{queue: "maintenance", max_attempts: 1} =
             ExpireRegistrations.new(%{}).changes
  end
end
