defmodule Tips.Workers.ExpireMedia do
  @moduledoc """
  Expires due unattached videos, at most fifty per run.

  Scheduled every minute on `media`. A run can take about three minutes when
  every Stream read times out; uniqueness across incomplete states keeps ticks
  from stacking behind it. There is no retry: the next tick is the retry, and
  a row whose read was uncertain waits out its cooldown so later rows progress.
  Each run logs its counts and duration.

  The rules live in `Tips.Content.Media.expire_due/1`.
  """
  use Oban.Worker,
    queue: :media,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias Tips.Content.Media

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, summary} = Media.expire_due()

    Logger.info(
      "Media expiry: retired=#{summary.retired} transitioned=#{summary.transitioned} " <>
        "deferred=#{summary.deferred} uncertain=#{summary.uncertain} in #{summary.duration_ms} ms"
    )

    {:ok, summary}
  end
end
