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

  Storage is split into three capacity classes with fixed row allocations:
  `:auth` (destination and IP buckets together), `:write` and `:upload`. Their
  sum is the table's hard bound. Classes never lend rows to each other, so an
  anonymous auth flood cannot deny signed-in writes or uploads. Each class
  tracks its row count and earliest expiry. A live bucket is never evicted: a
  request that needs a new row in a full class first reclaims that class's
  expired rows, but only once its earliest expiry is due. Otherwise it is denied
  with `:capacity` and a retry for that class's earliest expiry, without a scan.
  Buckets that already exist keep working while their class is full.

  Bounded storage has a cost: enough new identities (for example, many client
  IPs) can fill the auth class and deny new auth identities until rows expire.
  Signed-in writes and uploads are unaffected.

  Every `:cleanup_interval_ms` a sweep reclaims expired rows of each class whose
  earliest expiry is due. A reclaim is one scan of the capped table plus one to
  find the new earliest expiry. Keys are fixed size (digest, IP tuple or account
  id).

  IPs are exact addresses. A client that rotates addresses, including within one
  IPv6 prefix, gets new IP buckets; the destination bucket still bounds mail to
  each address.

  One process owns the table and serializes each admission decision, so
  concurrent callers cannot overspend. Buckets live in memory: a restart or
  deploy resets them, and each node would count separately.
  """

  use GenServer

  alias Tips.Accounts.{Scope, User}

  @max_destination_bytes 1_024
  @max_destination_length 160
  # The Tips.Accounts.User email format, plus no control characters.
  @email_format ~r/^[^@,;\s\p{Cc}]+@[^@,;\s\p{Cc}]+$/u
  @classes %{auth: [:auth_destination, :auth_ip], write: [:write], upload: [:upload]}

  @type server :: GenServer.server()
  @type result ::
          :ok
          | {:error, {:rate_limited | :capacity, pos_integer()}}
          | {:error, :invalid_identity}

  ## Client

  @doc """
  Starts a limiter.

  Options: `:auth_destination`, `:auth_ip`, `:write` and `:upload` as
  `{limit, window_ms}`; `:capacity`, rows per class as
  `[auth: rows, write: rows, upload: rows]`; `:cleanup_interval_ms`; `:clock`, a
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
      admit(server, :auth, [{:auth_destination, digest}, {:auth_ip, ip}])
    end
  end

  @doc "Admits one write by the scope's account."
  @spec check_write(term(), server()) :: result()
  def check_write(scope, server \\ __MODULE__) do
    with {:ok, id} <- account_id(scope), do: admit(server, :write, [{:write, id}])
  end

  @doc "Admits one upload by the scope's account."
  @spec check_upload(term(), server()) :: result()
  def check_upload(scope, server \\ __MODULE__) do
    with {:ok, id} <- account_id(scope), do: admit(server, :upload, [{:upload, id}])
  end

  defp admit(server, class, keys), do: GenServer.call(server, {:admit, class, keys})

  defp destination_digest(destination)
       when is_binary(destination) and byte_size(destination) <= @max_destination_bytes do
    with true <- String.valid?(destination),
         normalized = User.normalize_email(destination),
         true <- String.length(normalized) <= @max_destination_length,
         true <- normalized =~ @email_format do
      {:ok, :crypto.hash(:sha256, normalized)}
    else
      false -> {:error, :invalid_identity}
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
    capacity = Keyword.fetch!(opts, :capacity)

    state = %{
      table: :ets.new(__MODULE__, [:set, :protected]),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      policies:
        Map.new([:auth_destination, :auth_ip, :write, :upload], &{&1, fetch_policy!(opts, &1)}),
      # A new auth identity needs two rows at once.
      capacity: Map.new(@classes, fn {class, _} -> {class, fetch_rows!(capacity, class)} end),
      counts: Map.new(@classes, fn {class, _} -> {class, 0} end),
      earliest: Map.new(@classes, fn {class, _} -> {class, :infinity} end),
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

  defp fetch_rows!(capacity, class) do
    rows = Keyword.fetch!(capacity, class)
    true = is_integer(rows) and rows >= length(Map.fetch!(@classes, class))
    rows
  end

  @impl true
  def handle_call({:admit, class, keys}, _from, state) do
    now = state.clock.()
    buckets = Enum.map(keys, &bucket(&1, now, state))

    case spent_retry_ms(buckets, now) do
      nil -> admit_with_room(class, buckets, now, state)
      retry_ms -> {:reply, {:error, {:rate_limited, seconds(retry_ms)}}, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = state.clock.()
    state = Enum.reduce(Map.keys(@classes), state, &reclaim_if_due(&1, now, &2))
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

  defp admit_with_room(class, buckets, now, state) do
    state = if fits?(class, buckets, state), do: state, else: reclaim_if_due(class, now, state)

    if fits?(class, buckets, state) do
      {:reply, :ok, Enum.reduce(buckets, state, &consume(&1, class, now, &2))}
    else
      {:reply, {:error, {:capacity, seconds(state.earliest[class] - now)}}, state}
    end
  end

  # Expired rows still stored are overwritten in place, so only absent keys need a row.
  defp fits?(class, buckets, state) do
    new_rows = Enum.count(buckets, fn {key, _, _, _} -> not :ets.member(state.table, key) end)
    state.counts[class] + new_rows <= state.capacity[class]
  end

  # `earliest` is never later than the class's true earliest expiry: inserts lower
  # it and only a reclaim raises it. While it is in the future nothing in the class
  # can have expired, so the scan is skipped and the retry is exact.
  defp reclaim_if_due(class, now, state) do
    if state.earliest[class] > now do
      state
    else
      policies = Map.fetch!(@classes, class)
      expired = for p <- policies, do: {{{p, :_}, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}
      expiries = for p <- policies, do: {{{p, :_}, :_, :"$1"}, [], [:"$1"]}
      reclaimed = :ets.select_delete(state.table, expired)
      earliest = state.table |> :ets.select(expiries) |> Enum.min(fn -> :infinity end)

      %{
        state
        | counts: Map.update!(state.counts, class, &(&1 - reclaimed)),
          earliest: Map.put(state.earliest, class, earliest)
      }
    end
  end

  defp consume({key, _limit, _window_ms, {_count, _expires_at}}, _class, _now, state) do
    :ets.update_counter(state.table, key, {2, 1})
    state
  end

  defp consume({key, _limit, window_ms, nil}, class, now, state) do
    new_row? = not :ets.member(state.table, key)
    expires_at = now + window_ms
    :ets.insert(state.table, {key, 1, expires_at})

    %{
      state
      | counts: if(new_row?, do: Map.update!(state.counts, class, &(&1 + 1)), else: state.counts),
        earliest: Map.update!(state.earliest, class, &min(&1, expires_at))
    }
  end

  defp seconds(ms), do: max(div(ms + 999, 1_000), 1)
end
