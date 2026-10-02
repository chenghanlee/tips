defmodule Tips.ObanConfigTest do
  use ExUnit.Case, async: true

  alias Tips.Workers.ExpireRegistrations

  test "Oban is supervised with the three configured single-concurrency queues" do
    oban = Oban.whereis(Oban)
    assert is_pid(oban)

    assert Enum.any?(Supervisor.which_children(Tips.Supervisor), fn
             {Oban, ^oban, :supervisor, _} -> true
             _ -> false
           end)

    queues = Application.fetch_env!(:tips, Oban)[:queues]
    assert Keyword.keys(queues) == [:media, :embeddings, :maintenance]
    assert Enum.all?(queues, fn {_queue, limit} -> limit == 1 end)
  end

  test "registration expiry runs every minute on the maintenance queue" do
    # Tests run Oban in manual mode, which starts no plugins; build the config as other
    # environments do. `Oban.Config.new/1` also validates the crontab.
    config = Keyword.put(Application.fetch_env!(:tips, Oban), :testing, :disabled)

    assert %Oban.Config{plugins: plugins} = Oban.Config.new(config)

    assert {Oban.Cron, crontab: [{"* * * * *", ExpireRegistrations}]} =
             List.keyfind(plugins, Oban.Cron, 0)

    assert %{queue: "maintenance", max_attempts: 1} =
             ExpireRegistrations.new(%{}).changes
  end
end
