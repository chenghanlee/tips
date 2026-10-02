defmodule Tips.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query
  alias Tips.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  # It is very important to keep the magic link token expiry short,
  # since someone with access to the email may take over the account.
  @magic_link_validity_in_minutes 15
  @change_email_validity_in_days 7
  @session_validity_in_days 60

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    field :session_family_id, Ecto.UUID
    belongs_to :user, Tips.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie. As they are signed, those
  tokens do not need to be hashed.

  The reason why we store session tokens in the database, even
  though Phoenix already provides a session cookie, is because
  Phoenix's default session cookies are not persisted, they are
  simply signed and potentially encrypted. This means they are
  valid indefinitely, unless you change the signing/encryption
  salt.

  Therefore, storing them allows individual user
  sessions to be expired. The token system can also be extended
  to store additional data, such as the device used for logging in.
  You could then use this information to display all valid sessions
  and devices in the UI and allow users to explicitly expire any
  session they deem invalid.
  """
  def build_session_token(user_id, session_family_id, authenticated_at) do
    token = :crypto.strong_rand_bytes(@rand_size)

    {token,
     %UserToken{
       token: token,
       context: "session",
       user_id: user_id,
       authenticated_at: authenticated_at,
       session_family_id: session_family_id
     }}
  end

  @doc "Session validity, shared by the session query, pruning and the remember-me cookie."
  def session_validity_in_days, do: @session_validity_in_days

  @doc """
  Returns the query for the unexpired session row matching the bearer `token`.
  """
  def valid_session_token_query(token) do
    valid_session(from token in UserToken, where: token.token == ^token)
  end

  @doc """
  Returns the query for the unexpired session row with id `token_id` that
  belongs to `user_id`.
  """
  def valid_session_row_query(token_id, user_id) do
    valid_session(
      from token in UserToken, where: token.id == ^token_id and token.user_id == ^user_id
    )
  end

  # The session validity definition: a "session" row that has not expired.
  defp valid_session(query) do
    from token in query,
      where: token.context == "session" and token.inserted_at > ^cutoff("session")
  end

  @doc """
  Turns a valid-session query into the admission lookup.

  It returns `{user, token_id, token_inserted_at}` for an undeleted account.
  The user carries current account state and the row's `authenticated_at`.
  """
  def admission_query(valid_session_query) do
    from token in valid_session_query,
      join: user in assoc(token, :user),
      where: is_nil(user.deleted_at),
      select: {%{user | authenticated_at: token.authenticated_at}, token.id, token.inserted_at}
  end

  @doc """
  Returns the query for expired rows of every known context.

  A row expires when its age reaches its context's validity. Rows of unknown
  contexts are never matched.
  """
  def expired_tokens_query do
    from token in UserToken,
      where:
        (token.context == "session" and token.inserted_at <= ^cutoff("session")) or
          (token.context == "login" and token.inserted_at <= ^cutoff("login")) or
          (like(token.context, "change:%") and token.inserted_at <= ^cutoff("change:"))
  end

  # A row is valid while inserted after its context's cutoff.
  # Bind UTC instants: ago/2 casts to timestamp, which depends on the DB session zone.
  defp cutoff("session"), do: DateTime.add(DateTime.utc_now(), -@session_validity_in_days, :day)

  defp cutoff("login"),
    do: DateTime.add(DateTime.utc_now(), -@magic_link_validity_in_minutes, :minute)

  defp cutoff("change:" <> _),
    do: DateTime.add(DateTime.utc_now(), -@change_email_validity_in_days, :day)

  @doc """
  Builds a token and its hash to be delivered to the user's email.

  The non-hashed token is sent to the user email while the
  hashed part is stored in the database. The original token cannot be reconstructed,
  which means anyone with read-only access to the database cannot directly use
  the token in the application to gain access. Furthermore, if the user changes
  their email in the system, the tokens sent to the previous email are no longer
  valid.

  Users can easily adapt the existing code to provide other types of delivery methods,
  for example, by phone numbers.
  """
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  If found, the query returns a tuple of the form `{user, token}`.

  The given token is valid if it matches its hashed counterpart in the
  database. This function also checks whether the token has expired. The context
  of a magic link token is always "login".
  """
  def verify_magic_link_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "login"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ^cutoff("login"),
            where: token.sent_to == user.email,
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user_token found by the token, if any.

  This is used to validate requests to change the user
  email.
  The given token is valid if it matches its hashed counterpart in the
  database and if it has not expired (after @change_email_validity_in_days).
  The context must always start with "change:".
  """
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ^cutoff(context)

        {:ok, query}

      :error ->
        :error
    end
  end

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
