defmodule Tips.Content.Search.ProviderCapacity do
  @moduledoc """
  The one bound on concurrent embedding-provider requests, shared by reader
  queries and the embedding scan.

  A connection pool alone does not bound requests: HTTP/2 multiplexes many
  requests over one connection. Every `EmbeddingProvider` request holds one
  of `:size` slots for its whole duration. A caller waits for a free slot at
  most `:queue_wait` milliseconds, and never past its own deadline; the wait
  is part of that deadline. Waiters are served first come, first served.

  A slot is released when the request returns, raises or exits, and when its
  holder dies, so a cancelled or killed caller never leaks one. A waiter that
  gives up or dies leaves the queue.

  Settings live in `config/config.exs`.
  """

  @behaviour NimblePool

  @doc false
  def child_spec(_opts) do
    NimblePool.child_spec(worker: {__MODULE__, nil}, pool_size: config(:size), name: __MODULE__)
  end

  @doc """
  Runs `fun` while holding a slot, waiting at most until `deadline`
  (monotonic milliseconds) or for the configured queue wait, whichever is
  sooner. Returns `{:error, :busy}` when no slot frees in time.
  """
  @spec run(integer(), (-> result)) :: result | {:error, :busy} when result: term()
  def run(deadline, fun) do
    wait = min(config(:queue_wait), max(deadline - System.monotonic_time(:millisecond), 0))
    NimblePool.checkout!(__MODULE__, :run, fn _from, slot -> {fun.(), slot} end, wait)
  catch
    :exit, {:timeout, {NimblePool, :checkout, [__MODULE__]}} -> {:error, :busy}
  end

  defp config(key), do: :tips |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(key)

  @impl NimblePool
  def init_worker(pool_state), do: {:ok, :slot, pool_state}

  @impl NimblePool
  def handle_checkout(:run, _from, slot, pool_state), do: {:ok, slot, slot, pool_state}
end
