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
    * Public reads and rendering take no scope and look up no token.
    * Workers take ids in job args, reload committed state and never retain a
      browser scope or `Tips.Accounts.SessionRef`.

  ### Session validity

  `get_user_by_session_token/1`, through
  `Tips.Accounts.UserToken.verify_session_token_query/1`, is the only session
  validity definition: a matching `"session"` row that has not expired.
  Deleting the row revokes it. Controllers, LiveViews, renewal and pruning
  reuse it; do not add a second expiry constant or query.

  ### Runtime admission (#47, not implemented yet)

  These signatures are reserved. They do not exist yet.

    * `get_scope_by_session_token(token)` returns
      `{:ok, Scope.t(), SessionRef.t(), token_inserted_at}` or
      `{:error, :unauthenticated}`. It uses the validity definition above and
      also rejects deleted accounts.
    * `readmit_scope(session_ref)` returns `{:ok, Scope.t()}` or
      `{:error, :unauthenticated}`. It queries the referenced row, binds both
      ids, applies the same validity definition and loads current account
      state.

  A LiveView keeps its `SessionRef` in private state and re-admits before
  every mutation and privileged read. Controllers keep per-request
  authentication.

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
  alias Tips.Repo

  alias Tips.Accounts.{User, UserNotifier, UserToken}

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
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: User.normalize_email(email))
    if User.valid_password?(user, password), do: user
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

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
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

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Tips.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  This is the session validity definition; see the "Admission contract" section.
  """
  @spec get_user_by_session_token(binary()) :: {User.t(), DateTime.t()} | nil
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
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
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
