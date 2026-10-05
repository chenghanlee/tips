defmodule Tips.Accounts do
  @moduledoc """
  The Accounts context: identity, authentication and account lifecycle.

  ## Admission contract

  Authentication admits a caller. Eligibility decides whether that caller may
  perform one operation now. Keep them separate.

  ### Who builds identity

    * `TipsWeb.UserAuth` builds a `Tips.Accounts.Scope` from the server-side
      session for each controller request and LiveView mount. Anonymous
      callers have a `nil` scope.
    * Operations take the scope and business attrs as separate arguments.
      Ignore identity in attrs, params, events and job args; never turn it
      into a scope.
    * Public read APIs may take `scope | nil` for viewer-aware output. Their
      truly public projection needs no token lookup, no
      `Tips.Accounts.SessionRef` and no sign-in. An author- or moderator-only
      branch inside the same API still requires fresh admission before it
      returns privileged data; an optional scope alone never authorizes it.
      `Tips.Content.get_tip_page/2` and `Tips.Content.get_review_page/2`
      therefore take `nil` or a `Tips.Accounts.SessionRef` and call
      `readmit_scope/1` once at entry, never a caller-held scope.
    * Workers take ids in job args, reload committed state and never retain a
      browser scope or `Tips.Accounts.SessionRef`.

  ### Session validity

  `Tips.Accounts.UserToken` holds the only session validity definition: a
  `"session"` row that has not expired. Deleting the row revokes it. Bearer
  lookup, row-reference lookup, renewal and pruning reuse it; do not add a
  second expiry constant or query. Admission
  (`Tips.Accounts.UserToken.admission_query/1`) also requires an undeleted
  account.

  ### Session revocation

  A browser's session rows share one `session_family_id`. Logout and an
  account switch delete the whole family, so a successor issued by an earlier
  renewal cannot sign back in. Every revocation takes the account lock that
  renewal takes, then deletes rows; a renewal that waited on the lock finds no
  predecessor and issues nothing.

    * `revoke_user_session_family/1` revokes the family of one browser token.
    * `revoke_user_session_families/1` revokes every family of an account. It
      is the helper for email change and account deletion.
    * `login_user_by_magic_link/2` revokes the old family when the browser
      switches accounts.

  Each returns the revoked family ids. Deleting the rows is the authorization
  boundary. The caller passes the ids to `TipsWeb.UserAuth.disconnect_sessions/1`
  after its transaction commits; that broadcast is UI feedback only and may be
  lost. Inside a caller's transaction these helpers join it and roll back with
  it. Lock participating accounts in ascending id order before calling them.

  ### Registration deadline

  An unconfirmed registration expires seven days after its original
  `inserted_at`. Nothing moves that timestamp: resending a link and confirming
  leave it alone. `Tips.Accounts.User.registration_expired/1` is the only
  definition of the deadline, and four operations enforce it on the same
  account row:

    * `login_user_by_magic_link/2` rejects a link to an expired registration,
      even when cleanup has not run.
    * `register_user/1` reclaims expired registrations that hold the requested
      email or handle.
    * `expire_unconfirmed_users/1` deletes expired registrations in bounded
      maintenance batches.
    * `deliver_login_instructions/2` issues no link for an expired or deleted
      registration.

  Each locks the account, then judges confirmation and the deadline in a later
  statement against the database wall clock. Whichever commits first decides:
  a confirmed account is never deleted, and a deleted registration's tokens go
  with it, so they cannot authenticate the account that replaces it. Reclaim
  and cleanup lock several accounts in ascending id order, as login does.

  ### Runtime admission

    * `get_scope_by_session_token/1` admits a bearer token. Controllers call
      it on every request and LiveViews call it at mount, through
      `TipsWeb.UserAuth`. It returns the scope and a
      `Tips.Accounts.SessionRef` to the admitting row.
    * `readmit_scope/1` admits that reference again. It queries the referenced
      row, binds the row id and the mounted user id, applies the same validity
      definition and loads current account state: role, ban, confirmation and
      the row's authentication recency.

  Both return `{:error, :unauthenticated}` for an expired or revoked session,
  a deleted account and malformed input.

  A LiveView keeps its `SessionRef` in private state and re-admits with
  `TipsWeb.UserAuth.readmit/1` before every mutation and privileged read.
  Controllers keep per-request authentication. Rendering, form validation and
  public reads run no token query. Queries that bind the bearer or the
  reference are not logged, `TipsWeb.LiveLogger` logs LiveView callbacks
  without the session or payloads, and `TipsWeb.RequestLogger` logs request
  paths only after routing, as the route pattern when the path carries a token. Work admitted before a revocation may
  finish. Admission is not eligibility: a full ban or missing confirmation
  never fails admission.

  ### Operation eligibility

  The owning write operation locks the participating account row
  (`FOR NO KEY UPDATE`), calls `check_eligibility/2` on that locked row, then
  checks ownership and visibility. A scope admitted before a ban therefore
  cannot contribute after the ban commits.

  | Account | `:contribute` | `:moderate` | `:delete_own_content` | `:delete_account` |
  |---|---|---|---|---|
  | confirmed | ok | `:forbidden` | ok | ok |
  | unconfirmed | `:unconfirmed` | `:forbidden` | ok | ok |
  | full ban | `:forbidden` | `:forbidden` | ok | ok |
  | moderator | ok | ok | ok | ok |
  | unconfirmed moderator | `:unconfirmed` | `:unconfirmed` | ok | ok |
  | full-ban moderator | `:forbidden` | `:forbidden` | ok | ok |
  | deleted | `:unauthenticated` | `:unauthenticated` | `:unauthenticated` | `:unauthenticated` |

  `:contribute` covers publishing, editing, voting (including removal),
  reporting and upload authorization. `:moderate` covers moderation actions
  only. `check_eligibility/2` is not a read guard: a full ban preserves reading.
  Privileged reads (own hidden items, drafts, previews, moderator queue and
  hidden-content reads) need fresh admission plus the owning operation's
  current role, ownership and visibility checks. Account deletion also
  requires recent sign-in (`sudo_mode?/1`).

  ### Operation results

  Operations return `t:operation_result/1`. Each operation documents the
  subset it returns; there is no universal dispatcher. `:forbidden` covers
  full bans, non-owners and wrong roles. Whether a hidden resource reads as
  `:not_found` is the owning operation's projection choice. Never relabel an
  unknown infrastructure or provider outcome as one of these rejections.
  """

  import Ecto.Query, warn: false
  import Tips.Accounts.User, only: [registration_expired: 1]

  alias Tips.Repo

  alias Tips.Accounts.{Scope, SessionRef, User, UserNotifier, UserToken}

  require Logger

  @typedoc "Standard rejection reasons for business operations, or invalid input."
  @type operation_error ::
          :unauthenticated
          | :unconfirmed
          | :forbidden
          | :not_found
          | :conflict
          | Ecto.Changeset.t()

  @type operation_result(value) :: {:ok, value} | {:error, operation_error()}

  @type operation :: :contribute | :moderate | :delete_own_content | :delete_account

  # Positive bigint ids; anything else cannot name a row.
  @row_ids 1..9_223_372_036_854_775_807

  # Queries that bind a session bearer or a `SessionRef` pass this, so Ecto
  # never logs those parameters. Their telemetry events still fire.
  @private_params [log: false]

  ## Eligibility

  @doc """
  Checks whether the account may perform `operation` now.

  Call it on the account row locked by the owning transaction. See the
  eligibility table in the module documentation.
  """
  @spec check_eligibility(User.t(), operation()) ::
          :ok | {:error, :unauthenticated | :unconfirmed | :forbidden}
  def check_eligibility(%User{deleted_at: %DateTime{}}, _operation),
    do: {:error, :unauthenticated}

  def check_eligibility(%User{}, operation)
      when operation in [:delete_own_content, :delete_account],
      do: :ok

  def check_eligibility(%User{role: role}, :moderate) when role != :moderator,
    do: {:error, :forbidden}

  def check_eligibility(%User{confirmed_at: nil}, operation)
      when operation in [:contribute, :moderate],
      do: {:error, :unconfirmed}

  def check_eligibility(%User{ban: :full}, operation)
      when operation in [:contribute, :moderate],
      do: {:error, :forbidden}

  def check_eligibility(%User{}, operation) when operation in [:contribute, :moderate], do: :ok

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: User.normalize_email(email))
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @handle_words ~w(amber birch cedar cloud coral delta ember fern harbor heron juniper
                   lake maple meadow orbit pebble pine river sage slate spruce stone tide willow)

  @doc """
  Suggests a handle: a neutral word and a random four-digit suffix, such as
  `"maple-4821"`.

  It reserves nothing and does not check availability: the unique index decides
  at registration.
  """
  @spec suggest_handle() :: String.t()
  def suggest_handle, do: "#{Enum.random(@handle_words)}-#{Enum.random(1000..9999)}"

  @doc """
  Registers a user.

  An expired registration that holds the requested email or handle is
  reclaimed first, in the same transaction as the insert: if the insert then
  fails, nothing is deleted. Invalid input deletes nothing either. See
  "Registration deadline" in the module documentation.

  Returns `{:error, :registration_invariant}` when a reclaimed account still
  has contributions. That is an operational failure, not a taken email or
  handle: nothing is deleted and the caller keeps the submitted input.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec register_user(map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | :registration_invariant}
  def register_user(attrs) do
    Repo.transact(fn ->
      reclaim_expired_registrations(attrs)

      %User{}
      |> User.registration_changeset(attrs)
      |> Repo.insert()
    end)
  rescue
    error in Postgrex.Error ->
      case error do
        # Only the reclaim can violate a foreign key: `users` references nothing.
        %{postgres: %{code: :foreign_key_violation, constraint: constraint}} ->
          Logger.error("registration reclaim blocked by foreign key #{constraint}")
          {:error, :registration_invariant}

        _other ->
          reraise error, __STACKTRACE__
      end
  end

  # Only well-formed input names an identity to reclaim.
  defp reclaim_expired_registrations(attrs) do
    case User.registration_changeset(%User{}, attrs, validate_unique: false) do
      %Ecto.Changeset{valid?: true, changes: %{email: email, handle: handle}} ->
        delete_expired_registrations(
          from(u in User,
            where:
              fragment("lower(?)", u.email) == ^email or
                fragment("lower(?)", u.handle) == ^String.downcase(handle)
          )
        )

      %Ecto.Changeset{valid?: false} ->
        0
    end
  end

  @doc """
  Deletes up to `limit` expired registrations, lowest id first, and returns
  `{:ok, count}`.

  One call is one bounded batch; the maintenance schedule makes further
  progress. See "Registration deadline" in the module documentation. An
  account that still has contributions raises the foreign-key error and
  deletes nothing.
  """
  @spec expire_unconfirmed_users(1..100) :: {:ok, non_neg_integer()}
  def expire_unconfirmed_users(limit \\ 100) when limit in 1..100 do
    Repo.transact(fn ->
      {:ok,
       delete_expired_registrations(
         from(u in User, where: registration_expired(u), limit: ^limit)
       )}
    end)
  end

  # The one guarded deletion behind signup reclaim and maintenance cleanup. Call it in a
  # transaction. It locks the candidate accounts in ascending id order, waiting for any
  # confirmation in progress, then deletes those that are expired when the delete runs.
  # FOR UPDATE is the lock a delete needs, so nothing is upgraded while other locks are
  # held. The tokens go with the account through their foreign key.
  defp delete_expired_registrations(candidates) do
    ids = Repo.all(from(u in candidates, order_by: u.id, lock: "FOR UPDATE", select: u.id))

    {count, _} =
      Repo.delete_all(from(u in User, where: u.id in ^ids and registration_expired(u)))

    count
  end

  @doc """
  Returns a registration changeset for a user's handle and email.

  See `Tips.Accounts.User.registration_changeset/3` for supported options.
  """
  def change_user_registration(user, attrs \\ %{}, opts \\ []) do
    User.registration_changeset(user, attrs, opts)
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Tips.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  ## Session

  @doc """
  Generates a session token after genuine authentication.

  The token records the current time as `authenticated_at`. Without a
  predecessor it starts a new session family. Given the browser's current
  session token, it keeps that token's family when the token is a valid
  session of the same account, and starts a new family otherwise. Background
  renewal must use `renew_user_session_token/2` instead.
  """
  def generate_user_session_token(user, predecessor_token \\ nil)

  def generate_user_session_token(%User{id: user_id}, nil) do
    insert_session_token!(user_id, Ecto.UUID.generate(), DateTime.utc_now(:second))
  end

  def generate_user_session_token(%User{id: user_id}, predecessor_token) do
    {:ok, token} =
      Repo.transact(fn ->
        family =
          case lock_valid_predecessor(user_id, predecessor_token) do
            %UserToken{session_family_id: family} -> family
            nil -> Ecto.UUID.generate()
          end

        {:ok, insert_session_token!(user_id, family, DateTime.utc_now(:second))}
      end)

    token
  end

  @doc """
  Renews a session from its predecessor token without authenticating again.

  Locks the account, then requires the predecessor to be an unexpired session
  of the same, non-deleted account. The successor copies the predecessor's
  family and `authenticated_at` from the database; the predecessor stays valid
  until it expires. Returns `{:error, :unauthenticated}` and creates nothing
  otherwise.
  """
  @spec renew_user_session_token(User.t(), binary()) ::
          {:ok, binary()} | {:error, :unauthenticated}
  def renew_user_session_token(%User{id: user_id}, predecessor_token) do
    Repo.transact(fn ->
      case lock_valid_predecessor(user_id, predecessor_token) do
        %UserToken{session_family_id: family, authenticated_at: authenticated_at} ->
          {:ok, insert_session_token!(user_id, family, authenticated_at)}

        nil ->
          {:error, :unauthenticated}
      end
    end)
  end

  # Account lock first, then the predecessor under the shared validity definition.
  defp lock_valid_predecessor(user_id, token) do
    account =
      from(u in User,
        where: u.id == ^user_id and is_nil(u.deleted_at),
        lock: "FOR NO KEY UPDATE",
        select: u.id
      )

    if Repo.one(account), do: valid_predecessor(user_id, token)
  end

  # Call with the account locked.
  defp valid_predecessor(user_id, token) do
    Repo.one(
      from(t in UserToken.valid_session_token_query(token), where: t.user_id == ^user_id),
      @private_params
    )
  end

  defp insert_session_token!(user_id, family, authenticated_at) do
    {token, user_token} = UserToken.build_session_token(user_id, family, authenticated_at)
    Repo.insert!(user_token, @private_params)
    token
  end

  @doc """
  Deletes up to `limit` expired tokens, oldest first, and returns the count.

  Expiry uses each context's validity, so pruning an expired session never
  touches younger sessions of the same family.
  """
  @spec prune_expired_user_tokens(pos_integer()) :: non_neg_integer()
  def prune_expired_user_tokens(limit \\ 1000) when is_integer(limit) and limit > 0 do
    expired =
      from(t in UserToken.expired_tokens_query(),
        order_by: [asc: t.inserted_at, asc: t.id],
        limit: ^limit,
        select: t.id
      )

    {count, _} = Repo.delete_all(from(t in UserToken, where: t.id in subquery(expired)))
    count
  end

  @doc """
  Returns the family id of a valid session token, or `nil`.
  """
  @spec get_session_family_id(binary()) :: Ecto.UUID.t() | nil
  def get_session_family_id(token) do
    Repo.one(
      from(t in UserToken.valid_session_token_query(token), select: t.session_family_id),
      @private_params
    )
  end

  @doc """
  Admits the bearer of a session token.

  Returns the current scope, the private reference to the admitting row and
  the row's insertion time. See "Runtime admission" in the module
  documentation.
  """
  @spec get_scope_by_session_token(term()) ::
          {:ok, Scope.t(), SessionRef.t(), DateTime.t()} | {:error, :unauthenticated}
  def get_scope_by_session_token(token) when is_binary(token) do
    with {:ok, %Scope{user: user} = scope, token_id, token_inserted_at} <-
           admit(UserToken.valid_session_token_query(token)) do
      {:ok, scope, %SessionRef{token_id: token_id, user_id: user.id}, token_inserted_at}
    end
  end

  def get_scope_by_session_token(_token), do: {:error, :unauthenticated}

  @doc """
  Admits a mounted session again and returns its current scope.

  The reference must be the one `get_scope_by_session_token/1` returned.
  Anything else, including ids outside the database range, is rejected. See
  "Runtime admission" in the module documentation.
  """
  @spec readmit_scope(term()) :: {:ok, Scope.t()} | {:error, :unauthenticated}
  def readmit_scope(%SessionRef{token_id: token_id, user_id: user_id})
      when token_id in @row_ids and user_id in @row_ids do
    with {:ok, scope, _token_id, _token_inserted_at} <-
           admit(UserToken.valid_session_row_query(token_id, user_id)) do
      {:ok, scope}
    end
  end

  def readmit_scope(_session_ref), do: {:error, :unauthenticated}

  defp admit(valid_session_query) do
    case Repo.one(UserToken.admission_query(valid_session_query), @private_params) do
      {%User{} = user, token_id, token_inserted_at} ->
        {:ok, Scope.for_user(user), token_id, token_inserted_at}

      nil ->
        {:error, :unauthenticated}
    end
  end

  @doc """
  Gets the user with the given session token.

  Returns `{user, token_inserted_at}` when `get_scope_by_session_token/1`
  admits the token, otherwise `nil`.
  """
  @spec get_user_by_session_token(binary()) :: {User.t(), DateTime.t()} | nil
  def get_user_by_session_token(token) do
    case get_scope_by_session_token(token) do
      {:ok, %Scope{user: user}, _session_ref, token_inserted_at} -> {user, token_inserted_at}
      {:error, :unauthenticated} -> nil
    end
  end

  @doc """
  Gets the user with the given magic link token, or `nil` when the link is
  invalid or expired or belongs to an expired registration.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link and issues the session token.

  `predecessor_token` is the browser's current session token, if any. One
  transaction locks the participating accounts in ascending id order,
  revalidates the proof, consumes it and inserts the session token:

    * A valid predecessor of the same account keeps its family; the new token
      records the current time as `authenticated_at`.
    * A predecessor of another account is an account switch: its whole family
      is revoked and the new account starts a fresh family.
    * Otherwise a fresh family starts.

  An unconfirmed user is confirmed and all of their earlier tokens are
  deleted. `revoked_family_ids` lists every session family deleted here; the
  caller disconnects them after this returns.

  A rejected proof returns `{:error, :not_found}` and changes nothing. That
  includes a link to an expired registration: the proof is read again after
  the account lock, so a wait that crosses the deadline is rejected too.
  """
  @spec login_user_by_magic_link(binary(), binary() | nil) ::
          {:ok, %{user: User.t(), session_token: binary(), revoked_family_ids: [Ecto.UUID.t()]}}
          | {:error, :not_found}
  def login_user_by_magic_link(token, predecessor_token \\ nil) do
    # Proof and predecessor rows never change account or family, so both can be read unlocked.
    with {:ok, {%User{id: user_id}, _proof}} <- magic_link_proof(token) do
      predecessor = session_row(predecessor_token)
      predecessor_ids = for %UserToken{user_id: id} <- [predecessor], do: id

      Repo.transact(fn ->
        lock_accounts([user_id | predecessor_ids])
        log_in_by_locked_magic_link(token, predecessor)
      end)
    end
  end

  # Builds the query at each call so expiry is judged after any lock wait.
  defp magic_link_proof(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {%User{}, %UserToken{}} = proof <- Repo.one(query) do
      {:ok, proof}
    else
      # :error is an undecodable token, nil an unknown or expired one
      result when result in [:error, nil] -> {:error, :not_found}
    end
  end

  defp log_in_by_locked_magic_link(token, predecessor) do
    with {:ok, {user, proof}} <- magic_link_proof(token) do
      {:ok, log_in_by_magic_link(user, proof, predecessor)}
    end
  end

  defp log_in_by_magic_link(user, proof, predecessor) do
    {user, confirmed_away} = consume_proof(user, proof)
    {family, switched_away} = continue_or_switch_family(user.id, predecessor)

    %{
      user: user,
      session_token: insert_session_token!(user.id, family, DateTime.utc_now(:second)),
      revoked_family_ids: confirmed_away ++ switched_away
    }
  end

  # First confirmation deletes every earlier token of the account, sessions included.
  defp consume_proof(%User{confirmed_at: nil} = user, _proof) do
    user = Repo.update!(User.confirm_changeset(user))
    tokens = from(t in UserToken, where: t.user_id == ^user.id)
    families = delete_session_rows(tokens)
    Repo.delete_all(tokens)
    {user, families}
  end

  defp consume_proof(user, proof) do
    Repo.delete!(proof)
    {user, []}
  end

  # `predecessor` is the row read before the locks. Pruning takes no account lock and may
  # have deleted it since, so the family to revoke comes from that row, not a second lookup.
  # Keeping a family still needs the row to be valid now.
  defp continue_or_switch_family(_user_id, nil), do: {Ecto.UUID.generate(), []}

  defp continue_or_switch_family(user_id, %UserToken{user_id: user_id, token: token}) do
    case valid_predecessor(user_id, token) do
      %UserToken{session_family_id: family} -> {family, []}
      nil -> {Ecto.UUID.generate(), []}
    end
  end

  defp continue_or_switch_family(_user_id, %UserToken{} = other_account_row) do
    {Ecto.UUID.generate(), delete_session_rows(family_query(other_account_row))}
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  The token is committed before the bounded mail attempt; a delivery error
  leaves it and the current email in place. See `Tips.Accounts.UserNotifier`
  for the results.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  @spec deliver_user_update_email_instructions(User.t(), String.t(), (String.t() -> String.t())) ::
          UserNotifier.result()
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.

  The caller read `user` without a lock, so cleanup or reclaim may have
  deleted the account since, or its registration may have expired. Then no
  token is issued, nothing is sent and the result is `{:error, :not_found}`.
  The token is committed before the bounded mail attempt, whose delivery
  errors are described in `Tips.Accounts.UserNotifier`.
  """
  @spec deliver_login_instructions(User.t(), (String.t() -> String.t())) ::
          UserNotifier.result() | {:error, :not_found}
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    with {:ok, encoded_token} <- issue_login_token(user) do
      UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
    end
  end

  # Takes the account lock that confirmation, cleanup and reclaim take, then judges the
  # account in a later statement. A token is never inserted for a deleted account.
  defp issue_login_token(%User{id: user_id} = user) do
    Repo.transact(fn ->
      lock_accounts([user_id])

      if Repo.exists?(from(u in User, where: u.id == ^user_id and not registration_expired(u))) do
        {encoded_token, user_token} = UserToken.build_email_token(user, "login")
        Repo.insert!(user_token)
        {:ok, encoded_token}
      else
        {:error, :not_found}
      end
    end)
  end

  ## Session revocation

  @doc """
  Revokes the session family of the given browser token.

  Reads the account and family from the stored session row, never from the
  browser. Locks the account, then deletes every session row of that family.
  An expired row still identifies its family here; it never authenticates.
  Returns `{:ok, [family_id]}`, or `{:ok, []}` when the token is `nil`, has no
  session row or its family is already gone. Other families and non-session
  tokens are untouched.

  See "Session revocation" in the module documentation for disconnects.
  """
  @spec revoke_user_session_family(binary() | nil) :: {:ok, [Ecto.UUID.t()]}
  def revoke_user_session_family(token) do
    case session_row(token) do
      %UserToken{user_id: user_id} = row ->
        Repo.transact(fn ->
          lock_accounts([user_id])
          {:ok, delete_session_rows(family_query(row))}
        end)

      nil ->
        {:ok, []}
    end
  end

  @doc """
  Revokes every session family of the account and returns their ids.

  Locks the account, then deletes its session rows only: login and
  email-change tokens stay. Called inside a transaction it joins that
  transaction and rolls back with it, so email change and account deletion can
  compose it with their own writes. See "Session revocation" in the module
  documentation for lock order and disconnects.
  """
  @spec revoke_user_session_families(User.t()) :: {:ok, [Ecto.UUID.t()]}
  def revoke_user_session_families(%User{id: user_id}) do
    Repo.transact(fn ->
      lock_accounts([user_id])
      {:ok, delete_session_rows(from(t in UserToken, where: t.user_id == ^user_id))}
    end)
  end

  # Ascending id order, the same account lock renewal takes.
  defp lock_accounts(ids) do
    for id <- ids |> Enum.uniq() |> Enum.sort() do
      Repo.one(from(u in User, where: u.id == ^id, lock: "FOR NO KEY UPDATE", select: u.id))
    end
  end

  # The stored session row of a token at any age, to identify its account and family.
  defp session_row(nil), do: nil

  defp session_row(token),
    do: Repo.get_by(UserToken, [token: token, context: "session"], @private_params)

  defp family_query(%UserToken{user_id: user_id, session_family_id: family}) do
    from(t in UserToken, where: t.user_id == ^user_id and t.session_family_id == ^family)
  end

  # Deletes the session rows of `query` and returns their distinct families.
  defp delete_session_rows(query) do
    {_count, families} =
      Repo.delete_all(
        from(t in query, where: t.context == "session", select: t.session_family_id)
      )

    Enum.uniq(families)
  end
end
