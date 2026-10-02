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

    test "the signup link drops an external return destination", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in?return_to=https%3A%2F%2Fevil.example%2F")

      assert has_element?(lv, ~s|a[href="/users/register"]|, "Sign up")
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
