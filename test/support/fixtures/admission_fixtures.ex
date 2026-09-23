defmodule Tips.AdmissionFixtures do
  @moduledoc """
  Isolated `Tips.AdmissionLimiter` instances with small limits and a manual clock.

  Each test owns its instance and clock, so tests stay async and never touch the
  supervised production instance or application env.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]
  import Supervisor, only: [child_spec: 2]

  alias Tips.AdmissionLimiter

  @defaults [
    auth_destination: {2, 1_000},
    auth_ip: {3, 1_000},
    write: {2, 1_000},
    upload: {1, 2_000},
    cleanup_interval_ms: :timer.hours(1)
  ]

  @capacity [auth: 100, write: 100, upload: 100]

  @doc """
  Starts an unnamed limiter under the test supervisor. Returns `%{limiter: pid, clock: clock}`.

  `:capacity` overrides merge into the default per-class capacity.
  """
  def start_limiter(opts \\ []) do
    clock = :atomics.new(1, signed: true)
    {capacity, opts} = Keyword.pop(opts, :capacity, [])

    opts =
      @defaults
      |> Keyword.merge(opts)
      |> Keyword.merge(
        capacity: Keyword.merge(@capacity, capacity),
        name: nil,
        clock: fn -> :atomics.get(clock, 1) end
      )

    spec = child_spec({AdmissionLimiter, opts}, id: make_ref())
    %{limiter: start_supervised!(spec), clock: clock}
  end

  @doc "Moves a fixture clock forward by `ms` milliseconds."
  def advance(clock, ms), do: :atomics.add(clock, 1, ms)

  @doc "Moves a fixture clock to an absolute time in milliseconds."
  def set_time(clock, ms), do: :atomics.put(clock, 1, ms)

  @doc "Number of bucket entries currently stored by the limiter."
  def entry_count(limiter), do: :ets.info(:sys.get_state(limiter).table, :size)

  @doc "Runs the limiter's periodic cleanup now and waits for it."
  def run_cleanup(limiter) do
    send(limiter, :cleanup)
    :sys.get_state(limiter)
    :ok
  end
end
