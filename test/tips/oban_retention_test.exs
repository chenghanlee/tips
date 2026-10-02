defmodule Tips.ObanRetentionTest do
  use Tips.DataCase, async: true

  alias Oban.{Engine, Job, Period}

  @states_with_clock [
    available: :scheduled_at,
    scheduled: :scheduled_at,
    executing: :attempted_at,
    retryable: :scheduled_at,
    completed: :completed_at,
    cancelled: :cancelled_at,
    discarded: :discarded_at
  ]

  defp job(state, at) do
    clock = Keyword.fetch!(@states_with_clock, state)

    %Job{worker: "Tips.Workers.ExpireRegistrations", queue: "maintenance", args: %{}}
    |> Ecto.Changeset.change(
      %{state: Atom.to_string(state), scheduled_at: at}
      |> Map.put(clock, at)
    )
    |> Repo.insert!()
  end

  # Tests run Oban in manual mode, which starts no plugins. This calls the engine the way
  # `Oban.Pruner` does on each tick, with the retention the application configures.
  defp prune do
    config = Keyword.put(Application.fetch_env!(:tips, Oban), :testing, :disabled)
    {Oban.Pruner, opts} = List.keyfind(Oban.Config.new(config).plugins, Oban.Pruner, 0)

    Engine.prune_jobs(Oban.config(), Job,
      limit: 10_000,
      max_age: Period.to_seconds(opts[:max_age])
    )
  end

  test "retention removes only terminal jobs older than seven days" do
    now = DateTime.utc_now()
    old = DateTime.add(now, -8, :day)
    recent = DateTime.add(now, -6, :day)

    old_jobs = Map.new(@states_with_clock, fn {state, _} -> {state, job(state, old)} end)
    recent_terminal = for state <- [:completed, :cancelled, :discarded], do: job(state, recent)

    assert {:ok, pruned} = prune()

    assert pruned |> Enum.map(& &1.id) |> Enum.sort() ==
             [:completed, :cancelled, :discarded] |> Enum.map(&old_jobs[&1].id) |> Enum.sort()

    for state <- [:available, :scheduled, :executing, :retryable] do
      assert %Job{} = Repo.reload(old_jobs[state]), "#{state} job was pruned"
    end

    for job <- recent_terminal, do: assert(%Job{} = Repo.reload(job))
  end
end
