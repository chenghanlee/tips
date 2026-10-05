defmodule Tips.Workers.EmbedSearch do
  @moduledoc """
  Embeds missing search vectors, one bounded scan per run.

  Scheduled every minute on `embeddings`, whose concurrency is 1. Uniqueness
  across incomplete states keeps ticks from building a backlog behind a slow
  scan. There is no retry: the next tick resumes where this one stopped, and
  row cooldowns keep a failing document from blocking the rest. Args are
  empty; no per-row jobs exist.

  A job left executing by a lost node blocks later ticks until Oban rescues
  it. That rescue is configured separately.

  The rules live in `Tips.Content.Search.Embeddings.scan/1`.
  """
  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias Tips.Content.Search.Embeddings

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, Embeddings.scan()}
end
