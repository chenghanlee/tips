defmodule TipsWeb.UserAuth do
  @moduledoc """
  Handles session authentication and LiveView authentication hooks.

  Controllers authenticate every request. A LiveView authenticates at mount
  and keeps a private reference to its session row; call `readmit/1` before
  every mutation and privileged read on a mounted socket. See the "Admission
  contract" section of `Tips.Accounts`.
  """

  use TipsWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Phoenix.LiveView
  alias Tips.Accounts
  alias Tips.Accounts.{Scope, SessionRef, UserToken}

  # Socket and conn private key of the admitting `Tips.Accounts.SessionRef`.
  @session_ref :tips_session_ref

  # The remember me cookie lives as long as the session token it carries.
  @max_cookie_age_in_days UserToken.session_validity_in_days()
  @remember_me_cookie "_tips_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # How old the session token should be before it is renewed. When a request is made
  # with a session token at least this old, a successor token in the same session family
  # is created and the session and remember-me cookies (if set) are updated with it.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in with a session token `Tips.Accounts` already committed.

  Genuine authentication issues the token in its own transaction; this only
  installs it. Redirects to the allowed destination `return_to/2` picks from
  `params["return_to"]` and the session's `:user_return_to`, or falls back to
  `signed_in_path/1`.
  """
  def log_in_user(conn, user, session_token, params \\ %{}) do
    user_return_to = return_to(params["return_to"], get_session(conn, :user_return_to))

    conn
    |> create_or_extend_session(user, session_token, params)
    |> delete_session(:user_return_to)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out.

  Revokes the browser's whole session family, then disconnects its sockets.
  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    {:ok, family_ids} = Accounts.revoke_user_session_family(get_session(conn, :user_token))
    disconnect_sessions(family_ids)

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Renews the session token once it reaches the configured age. A rejected
  renewal leaves the request unauthenticated.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {:ok, %Scope{user: user} = scope, session_ref, token_inserted_at} <-
           Accounts.get_scope_by_session_token(token),
         {:ok, conn} <- maybe_renew_user_session_token(conn, user, token, token_inserted_at) do
      conn
      |> assign(:current_scope, scope)
      |> put_private(@session_ref, session_ref)
    else
      nil -> assign(conn, :current_scope, nil)
      {:error, :unauthenticated} -> assign(conn, :current_scope, nil)
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  # Renew the session token once it reaches the configured reissue age. Renewal keeps the
  # family and authentication recency; it never falls back to issuing a fresh token.
  defp maybe_renew_user_session_token(conn, user, token, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      with {:ok, new_token} <- Accounts.renew_user_session_token(user, token) do
        remember_me = get_session(conn, :user_remember_me)

        {:ok,
         conn
         |> put_token_in_session(new_token)
         |> maybe_write_remember_me_cookie(new_token, %{}, remember_me)}
      end
    else
      {:ok, conn}
    end
  end

  # This function installs the session token issued by genuine authentication:
  # logging in or re-authenticating for sudo mode.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, user, token, params) do
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _user) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn, _user) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  # Every token of a browser's family shares one socket topic, so renewal keeps it.
  defp put_token_in_session(conn, token) do
    conn = put_session(conn, :user_token, token)

    case Accounts.get_session_family_id(token) do
      nil -> conn
      family_id -> put_session(conn, :live_socket_id, user_session_topic(family_id))
    end
  end

  @doc """
  Disconnects the sockets of the given session families.

  Call it after the revocation commits. It is immediate UI feedback only:
  deleting the session rows is what revokes admission.
  """
  def disconnect_sessions(family_ids) do
    Enum.each(family_ids, fn family_id ->
      TipsWeb.Endpoint.broadcast(user_session_topic(family_id), "disconnect", %{})
    end)
  end

  defp user_session_topic(family_id), do: "users_sessions:#{family_id}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule TipsWeb.PageLive do
        use TipsWeb, :live_view

        on_mount {TipsWeb.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{TipsWeb.UserAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    case mount_current_scope(socket, session) do
      %{assigns: %{current_scope: %Scope{}}} = socket -> {:cont, socket}
      socket -> {:halt, require_login(socket)}
    end
  end

  def on_mount(:require_sudo_mode, _params, session, socket) do
    case mount_current_scope(socket, session) do
      %{assigns: %{current_scope: %Scope{user: user}}} = socket ->
        if Accounts.sudo_mode?(user, -10),
          do: {:cont, socket},
          else: {:halt, require_reauthentication(socket)}

      socket ->
        {:halt, require_login(socket)}
    end
  end

  # Each mount, disconnected or connected, admits the session token once,
  # however many hooks run, and keeps the row reference in private state, so
  # both renders read as the same viewer (`viewer/1`).
  defp mount_current_scope(%{private: %{@session_ref => _}} = socket, _session), do: socket

  defp mount_current_scope(socket, session) do
    {scope, session_ref} = admit_session(session)

    socket
    |> LiveView.put_private(@session_ref, session_ref)
    |> Phoenix.Component.assign(:current_scope, scope)
  end

  defp admit_session(session) do
    case Accounts.get_scope_by_session_token(session["user_token"]) do
      {:ok, scope, session_ref, _token_inserted_at} -> {scope, session_ref}
      {:error, :unauthenticated} -> {nil, nil}
    end
  end

  @doc """
  Returns the viewer the mount hook, or `fetch_current_scope_for_user/2` for a
  request, admitted: its `Tips.Accounts.SessionRef`, or `nil` when anonymous.
  Pass it to the `Tips.Content` reads that take a viewer; they readmit it. It
  is the same on the disconnected and connected mounts. Keep it out of assigns
  and templates.
  """
  @spec viewer(LiveView.Socket.t() | Plug.Conn.t()) :: SessionRef.t() | nil
  def viewer(%LiveView.Socket{private: private}), do: private[@session_ref]
  def viewer(%Plug.Conn{private: private}), do: private[@session_ref]

  @doc """
  Admits a mounted LiveView socket again, from its private session reference.

  Call it before every mutation and privileged read, then use the returned
  socket: its `current_scope` holds the account's current role, ban,
  confirmation and authentication recency. It reads the reference the mount
  hook stored, never assigns, params or event payloads, so the identity stays
  the one that mounted.

  Returns `{:error, :unauthenticated}` when the session expired or was
  revoked, the account was deleted, or the socket has no reference. Send the
  caller to `require_login/1`. Eligibility stays with the owning operation: a
  full ban does not fail admission.

      def handle_event("save", params, socket) do
        case UserAuth.readmit(socket) do
          {:ok, socket} -> save(socket, params)
          {:error, :unauthenticated} -> {:noreply, UserAuth.require_login(socket)}
        end
      end
  """
  @spec readmit(LiveView.Socket.t()) :: {:ok, LiveView.Socket.t()} | {:error, :unauthenticated}
  def readmit(%LiveView.Socket{private: private} = socket) do
    with %SessionRef{} = session_ref <- private[@session_ref],
         {:ok, scope} <- Accounts.readmit_scope(session_ref) do
      {:ok, Phoenix.Component.assign(socket, :current_scope, scope)}
    else
      _ -> {:error, :unauthenticated}
    end
  end

  @doc "Redirects a LiveView socket that failed admission to the log-in page."
  @spec require_login(LiveView.Socket.t()) :: LiveView.Socket.t()
  def require_login(socket) do
    socket
    |> LiveView.put_flash(:error, "You must log in to access this page.")
    |> LiveView.redirect(to: ~p"/users/log-in")
  end

  @doc "Redirects a LiveView socket whose sign-in is too old to the log-in page."
  @spec require_reauthentication(LiveView.Socket.t()) :: LiveView.Socket.t()
  def require_reauthentication(socket) do
    socket
    |> LiveView.put_flash(:error, "You must re-authenticate to access this page.")
    |> LiveView.redirect(to: ~p"/users/log-in")
  end

  # Positive bigint ids, as the review and editor routes take them, and
  # `Tips.Content.Projection` slugs.
  @id "[1-9]\\d{0,18}"
  @slug "(?=[a-z0-9-]{1,80}\\z)[a-z0-9]+(-[a-z0-9]+)*"

  # The root, settings, the review page, and the editor routes of the frontend design.
  @return_to ~r"\A/(users/settings|reviews/#{@id}|editor/(tips/new|tips/#{@id}/edit|tips/#{@id}/reviews/new|reviews/#{@id}/edit))?\z"

  # The public tip page; `TipsWeb.TipId` judges its base36 id.
  @tip_return_to ~r"\A/tips/([^/]+)/#{@slug}\z"

  @doc """
  Returns `path` if it is an allowed local return destination, otherwise `nil`.

  Only the root, settings, the public tip and review pages and the editor routes
  are allowed. The whole path must match, so schemes, `//`, backslashes, percent
  escapes, queries, fragments and control characters are rejected. Check every
  carrier with it when accepting and when consuming a destination.
  """
  @spec allowed_return_to(term()) :: String.t() | nil
  def allowed_return_to(path) when is_binary(path) do
    if path =~ @return_to or tip_return_to?(path), do: path
  end

  def allowed_return_to(_path), do: nil

  defp tip_return_to?(path) do
    case Regex.run(@tip_return_to, path, capture: :all_but_first) do
      [id | _slug_groups] -> match?({:ok, _id}, TipsWeb.TipId.decode(id))
      nil -> false
    end
  end

  @doc """
  Picks the destination to carry or redirect to: `explicit` if allowed,
  otherwise the session's `user_return_to` if allowed, otherwise `nil`.

  A rejected explicit value never hides a valid session destination.
  """
  @spec return_to(term(), term()) :: String.t() | nil
  def return_to(explicit, session_return_to) do
    allowed_return_to(explicit) || allowed_return_to(session_return_to)
  end

  @doc """
  Adds `return_to` to an authentication page `path` as its query; `nil` leaves
  `path` as it is.
  """
  @spec with_return_to(String.t(), String.t() | nil) :: String.t()
  def with_return_to(path, nil), do: path
  def with_return_to(path, return_to), do: path <> "?" <> URI.encode_query(return_to: return_to)

  @doc "Returns the path to redirect to after log in."
  # the user was already logged in, redirect to settings
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{user: %Accounts.User{}}}}) do
    ~p"/users/settings"
  end

  def signed_in_path(_), do: ~p"/"

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
