defmodule TipsWeb.UserAuthTest do
  use TipsWeb.ConnCase, async: true

  import Ecto.Query

  alias Phoenix.LiveView
  alias Tips.Accounts
  alias Tips.Accounts.Scope
  alias Tips.Repo
  alias TipsWeb.UserAuth

  import Tips.AccountsFixtures

  @remember_me_cookie "_tips_web_user_remember_me"
  @remember_me_cookie_max_age 60 * 60 * 24 * 60

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, TipsWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{user: %{user_fixture() | authenticated_at: DateTime.utc_now(:second)}, conn: conn}
  end

  describe "allowed_return_to/1" do
    test "admits only the root and the four editor route shapes" do
      for path <- [
            "/",
            "/editor/tips/new",
            "/editor/tips/42/edit",
            "/editor/tips/7/reviews/new",
            "/editor/reviews/9/edit",
            "/editor/tips/9223372036854775807/edit",
            "/editor/tips/9223372036854775807/reviews/new",
            "/editor/reviews/9223372036854775807/edit"
          ] do
        assert UserAuth.allowed_return_to(path) == path
      end

      for path <- [
            nil,
            "",
            42,
            "https://evil.example/",
            "//evil.example",
            "/\\evil.example",
            "/%2F%2Fevil.example",
            "/editor/tips/new?x=1",
            "/editor/tips/new#frag",
            "/editor/tips/new/",
            "/editor/tips/0/edit",
            "/editor/tips/-1/edit",
            "/editor/tips/01/edit",
            "/editor/tips/abc/edit",
            "/editor/tips/1/reviews/2/edit",
            "/editor/tips/new\n",
            "/editor/tips/new\u0000",
            "/users/settings",
            "/tips/1/slug"
          ] do
        assert UserAuth.allowed_return_to(path) == nil, "admitted #{inspect(path)}"
      end
    end
  end

  describe "log_in_user/4" do
    test "stores the user token in the session", %{conn: conn, user: user} do
      conn = log_in(conn, user)
      assert token = get_session(conn, :user_token)
      assert get_session(conn, :live_socket_id) == "users_sessions:#{token_row(token).family}"
      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_user_by_session_token(token)
    end

    test "clears everything previously stored in the session", %{conn: conn, user: user} do
      conn = conn |> put_session(:to_be_removed, "value") |> log_in(user)
      refute get_session(conn, :to_be_removed)
    end

    test "keeps session when re-authenticating", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> put_session(:to_be_removed, "value")
        |> log_in(user)

      assert get_session(conn, :to_be_removed)
    end

    test "installs the committed token without minting another", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)
      conn = UserAuth.log_in_user(conn, user, token)

      assert get_session(conn, :user_token) == token
      assert token_count(user) == 1
    end

    test "clears session when user does not match when re-authenticating", %{
      conn: conn,
      user: user
    } do
      other_user = user_fixture()

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(other_user))
        |> put_session(:to_be_removed, "value")
        |> log_in(user)

      refute get_session(conn, :to_be_removed)
    end

    test "redirects to the configured path", %{conn: conn, user: user} do
      conn = conn |> put_session(:user_return_to, "/hello") |> log_in(user)
      assert redirected_to(conn) == "/hello"
    end

    test "clears the return-to path from the session after logging in", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> put_session(:user_return_to, "/hello")
        |> log_in(user)

      assert redirected_to(conn) == "/hello"
      refute get_session(conn, :user_return_to)
    end

    test "writes a cookie if remember_me is configured", %{conn: conn, user: user} do
      conn = conn |> fetch_cookies() |> log_in(user, %{"remember_me" => "true"})
      assert get_session(conn, :user_token) == conn.cookies[@remember_me_cookie]
      assert get_session(conn, :user_remember_me) == true

      assert %{value: signed_token, max_age: max_age} = conn.resp_cookies[@remember_me_cookie]
      assert signed_token != get_session(conn, :user_token)
      assert max_age == @remember_me_cookie_max_age
    end

    test "redirects to settings when user is already logged in", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> log_in(user)

      assert redirected_to(conn) == ~p"/users/settings"
    end

    test "writes a cookie if remember_me was set in previous session", %{conn: conn, user: user} do
      conn = conn |> fetch_cookies() |> log_in(user, %{"remember_me" => "true"})
      assert get_session(conn, :user_token) == conn.cookies[@remember_me_cookie]
      assert get_session(conn, :user_remember_me) == true

      conn =
        conn
        |> recycle()
        |> Map.replace!(:secret_key_base, TipsWeb.Endpoint.config(:secret_key_base))
        |> fetch_cookies()
        |> init_test_session(%{user_remember_me: true})

      # the conn is already logged in and has the remember_me cookie set,
      # now we log in again and even without explicitly setting remember_me,
      # the cookie should be set again
      conn = conn |> log_in(user, %{})
      assert %{value: signed_token, max_age: max_age} = conn.resp_cookies[@remember_me_cookie]
      assert signed_token != get_session(conn, :user_token)
      assert max_age == @remember_me_cookie_max_age
      assert get_session(conn, :user_remember_me) == true
    end
  end

  describe "logout_user/1" do
    test "erases session and cookies", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)

      conn =
        conn
        |> put_session(:user_token, user_token)
        |> put_req_cookie(@remember_me_cookie, user_token)
        |> fetch_cookies()
        |> UserAuth.log_out_user()

      refute get_session(conn, :user_token)
      refute conn.cookies[@remember_me_cookie]
      assert %{max_age: 0} = conn.resp_cookies[@remember_me_cookie]
      assert redirected_to(conn) == ~p"/"
      refute Accounts.get_user_by_session_token(user_token)
    end

    test "logout broadcasts the family after committed revocation", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)
      {:ok, sibling} = Accounts.renew_user_session_token(user, token)
      other_browser = Accounts.generate_user_session_token(user)
      %{family: family} = token_row(token)
      TipsWeb.Endpoint.subscribe("users_sessions:#{family}")
      TipsWeb.Endpoint.subscribe("users_sessions:#{token_row(other_browser).family}")

      conn |> put_session(:user_token, sibling) |> UserAuth.log_out_user()

      topic = "users_sessions:#{family}"
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 50
      refute Accounts.get_user_by_session_token(token)
      refute Accounts.get_user_by_session_token(sibling)
      assert Accounts.get_user_by_session_token(other_browser)
    end

    test "revoked family cannot authenticate when disconnect is not delivered", %{
      conn: conn,
      user: user
    } do
      token = Accounts.generate_user_session_token(user)
      {:ok, sibling} = Accounts.renew_user_session_token(user, token)
      %{family: family} = token_row(token)
      # A tab that kept its session and never hears a disconnect.
      stale_session = %{"user_token" => sibling, "live_socket_id" => "users_sessions:#{family}"}

      assert {:ok, [^family]} = Accounts.revoke_user_session_family(token)

      refute Accounts.get_user_by_session_token(sibling)

      assert {:cont, %{assigns: %{current_scope: nil}}} =
               UserAuth.on_mount(:mount_current_scope, %{}, stale_session, %LiveView.Socket{})

      socket = %LiveView.Socket{
        endpoint: TipsWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:halt, %{assigns: %{current_scope: nil}}} =
               UserAuth.on_mount(:require_authenticated, %{}, stale_session, socket)

      conn =
        conn
        |> put_session(:user_token, sibling)
        |> UserAuth.fetch_current_scope_for_user([])
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert conn.assigns.current_scope == nil
      assert conn.halted
    end

    test "works even if user is already logged out", %{conn: conn} do
      conn = conn |> fetch_cookies() |> UserAuth.log_out_user()
      refute get_session(conn, :user_token)
      assert %{max_age: 0} = conn.resp_cookies[@remember_me_cookie]
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "fetch_current_scope_for_user/2" do
    test "authenticates user from session", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)

      conn =
        conn |> put_session(:user_token, user_token) |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id

      assert conn.assigns.current_scope.user.authenticated_at ==
               token_row(user_token).authenticated_at

      assert get_session(conn, :user_token) == user_token
    end

    test "authenticates user from cookies", %{conn: conn, user: user} do
      logged_in_conn =
        conn |> fetch_cookies() |> log_in(user, %{"remember_me" => "true"})

      user_token = logged_in_conn.cookies[@remember_me_cookie]
      %{value: signed_token} = logged_in_conn.resp_cookies[@remember_me_cookie]

      conn =
        conn
        |> put_req_cookie(@remember_me_cookie, signed_token)
        |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id

      assert conn.assigns.current_scope.user.authenticated_at ==
               token_row(user_token).authenticated_at

      assert get_session(conn, :user_token) == user_token
      assert get_session(conn, :user_remember_me)

      assert get_session(conn, :live_socket_id) ==
               "users_sessions:#{token_row(user_token).family}"
    end

    test "does not authenticate if data is missing", %{conn: conn, user: user} do
      _ = Accounts.generate_user_session_token(user)
      conn = UserAuth.fetch_current_scope_for_user(conn, [])
      refute get_session(conn, :user_token)
      refute conn.assigns.current_scope
    end

    test "does not renew just before seven days", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)
      backdate_token(token, -7, :day, 60)

      conn = conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id
      assert get_session(conn, :user_token) == token
      assert token_count(user) == 1
    end

    test "renews at seven days through a real signed remember-me cookie", %{
      conn: conn,
      user: user
    } do
      logged_in_conn =
        conn |> fetch_cookies() |> log_in(user, %{"remember_me" => "true"})

      token = get_session(logged_in_conn, :user_token)
      %{family: family} = token_row(token)
      stale = DateTime.add(DateTime.utc_now(:second), -1, :hour)
      override_token_authenticated_at(token, stale)
      backdate_token(token, -7, :day)

      conn =
        logged_in_conn
        |> recycle()
        |> Map.replace!(:secret_key_base, TipsWeb.Endpoint.config(:secret_key_base))
        |> init_test_session(%{})
        |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id
      assert conn.assigns.current_scope.user.authenticated_at == stale
      assert new_token = get_session(conn, :user_token)
      refute new_token == token
      assert %{family: ^family, authenticated_at: ^stale} = token_row(new_token)

      assert %{value: new_signed_token, max_age: @remember_me_cookie_max_age} =
               conn.resp_cookies[@remember_me_cookie]

      conn =
        conn
        |> recycle()
        |> Map.replace!(:secret_key_base, TipsWeb.Endpoint.config(:secret_key_base))
        |> init_test_session(%{})
        |> UserAuth.fetch_current_scope_for_user([])

      assert conn.req_cookies[@remember_me_cookie] == new_signed_token
      assert conn.assigns.current_scope.user.id == user.id
      assert get_session(conn, :user_token) == new_token
      assert token_count(user) == 2
    end

    test "renewed siblings share one disconnect topic", %{conn: conn, user: user} do
      logged_in_conn = conn |> fetch_cookies() |> log_in(user, %{"remember_me" => "true"})
      token = get_session(logged_in_conn, :user_token)
      topic = "users_sessions:#{token_row(token).family}"
      assert get_session(logged_in_conn, :live_socket_id) == topic
      backdate_token(token, -7, :day)

      # Two responses renew the same token: one from the session, one from the cookie alone.
      from_session =
        conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

      from_cookie =
        logged_in_conn
        |> recycle()
        |> Map.replace!(:secret_key_base, TipsWeb.Endpoint.config(:secret_key_base))
        |> init_test_session(%{})
        |> UserAuth.fetch_current_scope_for_user([])

      siblings = Enum.map([from_session, from_cookie], &get_session(&1, :user_token))
      assert [_, _, _] = Enum.uniq([token | siblings])

      for renewed <- [from_session, from_cookie] do
        assert get_session(renewed, :live_socket_id) == topic
      end
    end

    test "a rejected renewal leaves the request unauthenticated without a new token", %{
      conn: conn,
      user: user
    } do
      token = Accounts.generate_user_session_token(user)
      backdate_token(token, -7, :day)
      delete_account(user)

      conn = conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope == nil
      assert token_count(user) == 1
    end

    test "sessions expire at 60 days", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)
      backdate_token(token, -60, :day)

      conn = conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope == nil
      assert token_count(user) == 1
    end
  end

  describe "on_mount :mount_current_scope" do
    setup %{conn: conn} do
      %{conn: UserAuth.fetch_current_scope_for_user(conn, [])}
    end

    test "assigns current_scope based on a valid user_token", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)
      session = conn |> put_session(:user_token, user_token) |> get_session()

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope.user.id == user.id
    end

    test "assigns nil to current_scope assign if there isn't a valid user_token", %{conn: conn} do
      user_token = "invalid_token"
      session = conn |> put_session(:user_token, user_token) |> get_session()

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope == nil
    end

    test "assigns nil to current_scope assign if there isn't a user_token", %{conn: conn} do
      session = conn |> get_session()

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope == nil
    end
  end

  describe "on_mount :require_authenticated" do
    test "authenticates current_scope based on a valid user_token", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)
      session = conn |> put_session(:user_token, user_token) |> get_session()

      {:cont, updated_socket} =
        UserAuth.on_mount(:require_authenticated, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope.user.id == user.id
    end

    test "redirects to login page if there isn't a valid user_token", %{conn: conn} do
      user_token = "invalid_token"
      session = conn |> put_session(:user_token, user_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: TipsWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_scope == nil
    end

    test "redirects to login page if there isn't a user_token", %{conn: conn} do
      session = conn |> get_session()

      socket = %LiveView.Socket{
        endpoint: TipsWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_scope == nil
    end
  end

  describe "on_mount :require_sudo_mode" do
    test "allows users that have authenticated in the last 10 minutes", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)
      session = conn |> put_session(:user_token, user_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: TipsWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:cont, _updated_socket} =
               UserAuth.on_mount(:require_sudo_mode, %{}, session, socket)
    end

    test "redirects when authentication is too old", %{conn: conn, user: user} do
      eleven_minutes_ago = DateTime.utc_now(:second) |> DateTime.add(-11, :minute)
      user_token = Accounts.generate_user_session_token(user)
      override_token_authenticated_at(user_token, eleven_minutes_ago)
      {user, token_inserted_at} = Accounts.get_user_by_session_token(user_token)
      assert DateTime.compare(token_inserted_at, user.authenticated_at) == :gt
      session = conn |> put_session(:user_token, user_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: TipsWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:halt, _updated_socket} =
               UserAuth.on_mount(:require_sudo_mode, %{}, session, socket)
    end
  end

  describe "require_authenticated_user/2" do
    setup %{conn: conn} do
      %{conn: UserAuth.fetch_current_scope_for_user(conn, [])}
    end

    test "redirects if user is not authenticated", %{conn: conn} do
      conn = conn |> fetch_flash() |> UserAuth.require_authenticated_user([])
      assert conn.halted

      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to access this page."
    end

    test "stores the path to redirect to on GET", %{conn: conn} do
      halted_conn =
        %{conn | path_info: ["foo"], query_string: ""}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn.halted
      assert get_session(halted_conn, :user_return_to) == "/foo"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar=baz"}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn.halted
      assert get_session(halted_conn, :user_return_to) == "/foo?bar=baz"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar", method: "POST"}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn.halted
      refute get_session(halted_conn, :user_return_to)
    end

    test "does not redirect if user is authenticated", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> UserAuth.require_authenticated_user([])

      refute conn.halted
      refute conn.status
    end
  end

  describe "disconnect_sessions/1" do
    test "broadcasts a disconnect on each family topic" do
      families = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      Enum.each(families, &TipsWeb.Endpoint.subscribe("users_sessions:#{&1}"))

      UserAuth.disconnect_sessions(families)

      for family <- families do
        topic = "users_sessions:#{family}"
        assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
      end
    end
  end

  # Genuine authentication as the controller does it: commit the token, then install it.
  defp log_in(conn, user, params \\ %{}) do
    token = Accounts.generate_user_session_token(user, get_session(conn, :user_token))
    UserAuth.log_in_user(conn, user, token, params)
  end

  defp token_row(token) do
    %{session_family_id: family, authenticated_at: authenticated_at} =
      Repo.get_by!(Accounts.UserToken, token: token, context: "session")

    %{family: family, authenticated_at: authenticated_at}
  end

  defp token_count(user) do
    Repo.aggregate(from(t in Accounts.UserToken, where: t.user_id == ^user.id), :count)
  end

  defp delete_account(user) do
    Repo.update_all(from(u in Accounts.User, where: u.id == ^user.id),
      set: [deleted_at: DateTime.utc_now(:second), handle: nil, email: nil]
    )
  end

  # Moves `inserted_at` to `amount` `unit`s ago, then `extra_seconds` closer to now.
  defp backdate_token(token, amount, unit, extra_seconds \\ 0) do
    inserted_at =
      DateTime.utc_now(:second) |> DateTime.add(amount, unit) |> DateTime.add(extra_seconds)

    assert {1, nil} =
             Repo.update_all(from(t in Accounts.UserToken, where: t.token == ^token),
               set: [inserted_at: inserted_at]
             )
  end
end
