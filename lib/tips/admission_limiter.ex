defmodule Tips.AdmissionLimiter do
  @moduledoc """
  Single-node admission limits for authentication mail, writes and uploads.

  Callers admit first and act only on `:ok`:

    1. Authenticate and authorize as the operation requires.
    2. Call `check_auth/3`, `check_write/2` or `check_upload/2`.
    3. Only on `:ok`, create a token, request a provider or mutate data.

  Admission consumes budget. Nothing refunds it: not a failed downstream step,
  not deleting the content. There is no reset API.

  ## Identity

    * `check_auth/3` takes the typed destination address and the trusted client
      IP from `TipsWeb.ClientIdentity`. It consumes two buckets atomically: the
      normalized destination (trim and downcase, like `Tips.Accounts.User`) and
      the IP. Rotating either one cannot evade the other. A denial consumes
      neither. ETS stores a SHA-256 digest of the destination, not the address.
    * `check_write/2` and `check_upload/2` take the server-built
      `Tips.Accounts.Scope` and charge its account id. A scope struct is not
      proof of authentication: the caller must build it from server state
      (`TipsWeb.UserAuth`, and fresh admission once #47 lands). Eligibility and
      locked business checks stay with the owning operation.

  Missing or malformed identities return `{:error, :invalid_identity}`. There is
  no shared "unknown" bucket.

  ## Results

    * `:ok`
    * `{:error, {:rate_limited, retry_after_seconds}}`: a bucket is spent.
    * `{:error, {:capacity, retry_after_seconds}}`: the table is full of live
      buckets.
    * `{:error, :invalid_identity}`

  Retry values are positive whole seconds, rounded up.

  ## Windows and storage

  Each bucket is a fixed window that starts at its first admission. A caller can
  spend a full budget just before a window ends and another just after, so the
  short-term burst is up to twice the budget. The budgets are in
  `config/config.exs`.

  The table holds at most `:max_entries` buckets. A live bucket is never evicted
  to make room: when the table is full, expired buckets are deleted, and if it
  is still full the request is denied with `:capacity`. Every
  `:cleanup_interval_ms` the same sweep deletes idle expired buckets. A sweep is
  one full scan of at most `:max_entries` rows, so its cost is bounded by the
  cap. Keys are fixed size (digest, IP tuple or account id).

  One process owns the table and serializes each admission decision, so
  concurrent callers cannot overspend. Buckets live in memory: a restart or
  deploy resets them, and each node would count separately.
  """

  use GenServer

  alias Tips.Accounts.{Scope, User}

  @max_destination_bytes 1_024
  @max_destination_length 160
  @email_format ~r/^[^@,;\s]+@[^@,;\s]+$/u

  @type server :: GenServer.server()
  @type result ::
          :ok
          | {:error, {:rate_limited | :capacity, pos_integer()}}
          | {:error, :invalid_identity}

  ## Client

  @doc """
  Starts a limiter.

  Options: `:auth_destination`, `:auth_ip`, `:write` and `:upload` as
  `{limit, window_ms}`; `:max_entries`; `:cleanup_interval_ms`; `:clock`, a
  zero-arity function returning monotonic milliseconds; and `:name` (default
  `#{inspect(__MODULE__)}`, `nil` for an unnamed instance).
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Admits one authentication mail request for `destination` from `trusted_ip`."
  @spec check_auth(term(), term(), server()) :: result()
  def check_auth(destination, trusted_ip, server \\ __MODULE__) do
    with {:ok, digest} <- destination_digest(destination),
         {:ok, ip} <- validate_ip(trusted_ip) do
      admit(server, [{:auth_destination, digest}, {:auth_ip, ip}])
    end
  end

  @doc "Admits one write by the scope's account."
  @spec check_write(term(), server()) :: result()
  def check_write(scope, server \\ __MODULE__) do
    with {:ok, id} <- account_id(scope), do: admit(server, [{:write, id}])
  end

  @doc "Admits one upload by the scope's account."
  @spec check_upload(term(), server()) :: result()
  def check_upload(scope, server \\ __MODULE__) do
    with {:ok, id} <- account_id(scope), do: admit(server, [{:upload, id}])
  end

  defp admit(server, keys), do: GenServer.call(server, {:admit, keys})

  defp destination_digest(destination)
       when is_binary(destination) and byte_size(destination) <= @max_destination_bytes do
    normalized = User.normalize_email(destination)

    if String.length(normalized) <= @max_destination_length and normalized =~ @email_format do
      {:ok, :crypto.hash(:sha256, normalized)}
    else
      {:error, :invalid_identity}
    end
  end

  defp destination_digest(_destination), do: {:error, :invalid_identity}

  defp validate_ip(ip) do
    if :inet.is_ip_address(ip), do: {:ok, ip}, else: {:error, :invalid_identity}
  end

  defp account_id(%Scope{user: %User{id: id}}) when is_integer(id) and id > 0, do: {:ok, id}
  defp account_id(_scope), do: {:error, :invalid_identity}

  ## Server

  @impl true
  def init(opts) do
    max_entries = Keyword.fetch!(opts, :max_entries)
    # Authentication needs room for two buckets at once.
    true = is_integer(max_entries) and max_entries >= 2

    state = %{
      table: :ets.new(__MODULE__, [:set, :protected]),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      policies:
        Map.new([:auth_destination, :auth_ip, :write, :upload], &{&1, fetch_policy!(opts, &1)}),
      max_entries: max_entries,
      cleanup_interval_ms: Keyword.fetch!(opts, :cleanup_interval_ms)
    }

    schedule_cleanup(state)
    {:ok, state}
  end

  defp fetch_policy!(opts, name) do
    {limit, window_ms} = policy = Keyword.fetch!(opts, name)
    true = is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0
    policy
  end

  @impl true
  def handle_call({:admit, keys}, _from, state) do
    now = state.clock.()
    buckets = Enum.map(keys, &bucket(&1, now, state))

    reply =
      cond do
        retry_ms = spent_retry_ms(buckets, now) ->
          {:error, {:rate_limited, seconds(retry_ms)}}

        not room?(keys, now, state) ->
          {:error, {:capacity, seconds(earliest_expiry(state.table) - now)}}

        true ->
          Enum.each(buckets, &consume(&1, now, state.table))
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    reclaim_expired(state.table, state.clock.())
    schedule_cleanup(state)
    {:noreply, state}
  end

  defp schedule_cleanup(state),
    do: Process.send_after(self(), :cleanup, state.cleanup_interval_ms)

  # {key, limit, window_ms, live entry or nil}
  defp bucket({policy, _id} = key, now, state) do
    {limit, window_ms} = Map.fetch!(state.policies, policy)

    case :ets.lookup(state.table, key) do
      [{^key, count, expires_at}] when expires_at > now ->
        {key, limit, window_ms, {count, expires_at}}

      _absent_or_expired ->
        {key, limit, window_ms, nil}
    end
  end

  defp spent_retry_ms(buckets, now) do
    buckets
    |> Enum.flat_map(fn
      {_key, limit, _window_ms, {count, expires_at}} when count >= limit -> [expires_at - now]
      _bucket -> []
    end)
    |> Enum.max(fn -> nil end)
  end

  defp room?(keys, now, state) do
    fits?(keys, state) or (reclaim_expired(state.table, now) > 0 and fits?(keys, state))
  end

  # Expired keys still stored are overwritten in place, so only absent keys grow the table.
  defp fits?(keys, %{table: table, max_entries: max_entries}) do
    :ets.info(table, :size) + Enum.count(keys, &(not :ets.member(table, &1))) <= max_entries
  end

  defp reclaim_expired(table, now) do
    :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  end

  defp earliest_expiry(table) do
    :ets.foldl(
      fn {_key, _count, expires_at}, earliest -> min(expires_at, earliest) end,
      :infinity,
      table
    )
  end

  defp consume({key, _limit, _window_ms, {_count, _expires_at}}, _now, table) do
    :ets.update_counter(table, key, {2, 1})
    :ok
  end

  defp consume({key, _limit, window_ms, nil}, now, table) do
    :ets.insert(table, {key, 1, now + window_ms})
    :ok
  end

  defp seconds(ms), do: max(div(ms + 999, 1_000), 1)
end
