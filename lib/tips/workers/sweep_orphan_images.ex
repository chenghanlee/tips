defmodule Tips.Workers.SweepOrphanImages do
  @moduledoc """
  Removes old image objects that no media row references, one listing page
  per execution.

  Scheduled weekly on `maintenance`. One job carries the whole chain: after a
  page with more to follow, it saves the next listing token in its args and
  snoozes, which keeps the args and uses no attempt. Uniqueness on worker and
  queue across incomplete states drops a weekly tick while a chain runs, so no
  cursor is lost. There is no retry: a listing error discards the job and the
  next weekly run starts over.

  The rules live in `Tips.Content.Media.sweep_orphans/2`.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete, fields: [:worker, :queue]]

  alias Tips.Content.Media

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    case Media.sweep_orphans(args["after"]) do
      {:continue, token} ->
        {:ok, _job} = Oban.update_job(job, %{args: %{"after" => token}})
        {:snooze, 5}

      result ->
        result
    end
  end
end
