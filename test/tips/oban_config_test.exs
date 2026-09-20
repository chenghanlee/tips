defmodule Tips.ObanConfigTest do
  use ExUnit.Case, async: true

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
end
