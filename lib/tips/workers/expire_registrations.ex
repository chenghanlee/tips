defmodule Tips.Workers.ExpireRegistrations do
  @moduledoc """
  Deletes expired unconfirmed registrations, one bounded batch per run.

  Scheduled every minute on `maintenance`. Uniqueness across incomplete states
  keeps ticks from building a backlog behind a slow run. There is no retry:
  the next tick is the retry. A failure, such as an expired registration that
  still has contributions, raises, so Oban records the job as failed and
  nothing is deleted.

  The rules live in `Tips.Accounts.expire_unconfirmed_users/1`.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias Tips.Accounts

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: Accounts.expire_unconfirmed_users()
end
