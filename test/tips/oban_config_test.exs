defmodule Tips.ObanConfigTest do
  use ExUnit.Case, async: true

  alias Tips.Workers.{EmbedSearch, ExpireRegistrations}

  test "registration expiry and the embedding scan each run every minute on their queue" do
    # Tests run Oban in manual mode, which starts no plugins; build the config as other
    # environments do. `Oban.Config.new/1` also validates the crontab.
    config = Keyword.put(Application.fetch_env!(:tips, Oban), :testing, :disabled)

    assert %Oban.Config{plugins: plugins, queues: queues} = Oban.Config.new(config)

    assert {Oban.Cron, crontab: [{"* * * * *", ExpireRegistrations}, {"* * * * *", EmbedSearch}]} =
             List.keyfind(plugins, Oban.Cron, 0)

    assert {Oban.Pruner, max_age: {7, :days}} = List.keyfind(plugins, Oban.Pruner, 0)
    assert queues[:embeddings] == [limit: 1]

    assert %{queue: "maintenance", max_attempts: 1} =
             ExpireRegistrations.new(%{}).changes

    assert %{queue: "embeddings", max_attempts: 1, unique: %{period: :infinity, states: states}} =
             EmbedSearch.new(%{}).changes

    assert MapSet.new(states) ==
             MapSet.new([:available, :scheduled, :executing, :retryable, :suspended])
  end
end
