defmodule TipsWeb.UserLive.LoginTest do
  use TipsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Log in"
      assert html =~ "Sign up"
      assert html =~ "Log in with email"
    end

    test "offers only the email magic-link form", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#login_form_magic input[type=email]")
      refute has_element?(lv, "#login_form_password")
      refute has_element?(lv, "input[type=password]")
      refute String.downcase(html) =~ "password"
    end

    test "prefills the email carried by registration delivery recovery", %{conn: conn} do
      email = unique_user_email()
      conn = init_test_session(conn, %{"phoenix_flash" => %{"email" => email}})

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, ~s|#login_form_magic input[type=email][value="#{email}"]|)
    end
  end

  describe "user login - magic link" do
    test "sends magic link email when user exists", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"

      assert Tips.Repo.get_by!(Tips.Accounts.UserToken, user_id: user.id).context ==
               "login"
    end

    test "an expired registration is told to register again and keeps the email and destination",
         %{conn: conn} do
      user = unconfirmed_user_fixture()
      set_registration_deadline(user, -1)
      {:ok, lv, _html} = live(conn, ~p"/users/log-in?return_to=%2Feditor%2Ftips%2Fnew")

      html = lv |> form("#login_form_magic", user: %{email: user.email}) |> render_submit()

      assert html =~ "was not confirmed within seven days and has expired. Register again"
      refute html =~ "If your email is in our system"

      assert has_element?(
               lv,
               ~s|#login_form_magic input[name="user[email]"][value="#{user.email}"]|
             )

      refute Tips.Repo.get_by(Tips.Accounts.UserToken, user_id: user.id)
      Swoosh.TestAssertions.assert_no_email_sent()

      # The destination came only from the query string; the signup link carries it on.
      {:ok, register, _html} =
        lv
        |> element(~s|a[href="/users/register?return_to=%2Feditor%2Ftips%2Fnew"]|, "Sign up")
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(register, ~s|a[href="/users/log-in?return_to=%2Feditor%2Ftips%2Fnew"]|)
    end

    # {query, session} => destination carried by the Sign up link after the expired answer.
    for {label, query, session, carried} <- [
          {"a valid query wins over the session", "/editor/tips/new", "/editor/tips/7/edit",
           "/editor/tips/new"},
          {"a missing query falls back to the session", nil, "/editor/tips/7/edit",
           "/editor/tips/7/edit"},
          {"an external query falls back to the session", "https://evil.example/editor/tips/new",
           "/editor/tips/7/edit", "/editor/tips/7/edit"},
          {"a disallowed local query falls back to the session", "/users/settings",
           "/editor/tips/7/edit", "/editor/tips/7/edit"},
          {"an external query and no session carry nothing", "//evil.example", nil, nil},
          {"a disallowed query and a disallowed session carry nothing", "/users/settings",
           "https://evil.example/", nil},
          {"no query and no session carry nothing", nil, nil, nil}
        ] do
      @query query
      @session session
      @carried carried
      test "expired sign-in restart: #{label}", %{conn: conn} do
        user = unconfirmed_user_fixture()
        set_registration_deadline(user, -1)
        session = if @session, do: %{"user_return_to" => @session}, else: %{}
        conn = Plug.Test.init_test_session(conn, session)
        path = if @query, do: ~p"/users/log-in?#{[return_to: @query]}", else: ~p"/users/log-in"

        {:ok, lv, _html} = live(conn, path)
        html = lv |> form("#login_form_magic", user: %{email: user.email}) |> render_submit()

        assert html =~ "has expired. Register again"

        assert has_element?(
                 lv,
                 ~s|#login_form_magic input[name="user[email]"][value="#{user.email}"]|
               )

        register_path =
          if @carried, do: ~p"/users/register?#{[return_to: @carried]}", else: ~p"/users/register"

        log_in_path =
          if @carried, do: ~p"/users/log-in?#{[return_to: @carried]}", else: ~p"/users/log-in"

        {:ok, register, _html} =
          lv
          |> element(~s|a[href="#{register_path}"]|, "Sign up")
          |> render_click()
          |> follow_redirect(conn)

        assert has_element?(register, ~s|a[href="#{log_in_path}"]|, "Log in")
      end
    end

    test "does not disclose if user is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the Register button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Sign up")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/register")

      assert login_html =~ "Register"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "You need to reauthenticate"
      refute html =~ "Register"
      assert html =~ "Log in with email"

      assert html =~
               ~s(<input type="email" name="user[email]" id="login_form_magic_email" value="#{user.email}")

      refute String.downcase(html) =~ "password"
    end
  end
end
