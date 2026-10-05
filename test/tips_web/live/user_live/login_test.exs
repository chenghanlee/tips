defmodule TipsWeb.UserLive.LoginTest do
  use TipsWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Tips.AccountsFixtures
  import Tips.AdmissionFixtures

  alias Tips.Accounts.UserToken
  alias Tips.{MailerTestAdapter, Repo}

  @peer {198, 51, 100, 7}
  @requested "If this email has an account, check your inbox for a sign-in link. " <>
               "If it hasn&#39;t arrived in a few minutes, request another."

  # Every test owns an isolated limiter and a fixed transport peer.
  setup %{conn: conn} do
    %{limiter: limiter} = start_limiter(auth_destination: {5, 60_000}, auth_ip: {20, 60_000})
    %{conn: limited_conn(conn, limiter)}
  end

  defp limited_conn(conn, limiter) do
    conn
    |> Plug.Test.init_test_session(%{"admission_limiter" => limiter})
    |> Plug.Test.put_peer_data(%{address: @peer, port: 40_000, ssl_cert: nil})
  end

  defp submit_magic(lv, email) do
    lv |> form("#login_form_magic", user: %{email: email}) |> render_submit()
  end

  defp email_value?(lv, email) do
    has_element?(lv, ~s|#login_form_magic input[name="user[email]"][value="#{email}"]|)
  end

  defp tokens, do: Repo.aggregate(UserToken, :count)

  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  describe "login page" do
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
    # {label, account?, scripted delivery} => one neutral answer that stays on the form.
    for {label, account?, script} <- [
          {"unknown address", false, nil},
          {"accepted", true, nil},
          {"provider rejection", true, :reject},
          {"timeout", true, :block}
        ] do
      @account account?
      @script script
      test "sign-in answers #{label} with the same neutral feedback on the form", %{conn: conn} do
        email = if @account, do: user_fixture().email, else: unique_user_email()
        flush_emails()
        if @script, do: MailerTestAdapter.script(@script)
        {:ok, lv, _html} = live(conn, ~p"/users/log-in?return_to=%2Feditor%2Ftips%2Fnew")

        html = submit_magic(lv, email)

        assert html =~ @requested
        refute has_element?(lv, "#flash-error")
        assert email_value?(lv, email)
        assert has_element?(lv, ~s|a[href="/users/register?return_to=%2Feditor%2Ftips%2Fnew"]|)

        case {@account, @script} do
          {false, nil} -> assert_no_email_sent()
          {true, nil} -> assert_email_sent(to: email)
          {true, _failure} -> assert_received {:mail_attempt, _attempt}
        end

        refute_received {:mail_attempt, _retry}
      end
    end

    test "an expired registration is told to register again and keeps the email and destination",
         %{conn: conn} do
      user = unconfirmed_user_fixture()
      set_registration_deadline(user, -1)
      {:ok, lv, _html} = live(conn, ~p"/users/log-in?return_to=%2Feditor%2Ftips%2Fnew")

      html = lv |> form("#login_form_magic", user: %{email: user.email}) |> render_submit()

      assert html =~ "was not confirmed within seven days and has expired. Register again"
      refute html =~ @requested

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
          {"a disallowed query and a disallowed session carry nothing", "/users/settings",
           "https://evil.example/", nil}
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
  end

  describe "admission limits" do
    test "auth mail denial has no token or provider side effects" do
      %{limiter: limiter} = start_limiter(auth_destination: {1, 60_000})
      known = user_fixture().email
      flush_emails()

      for email <- [known, unique_user_email()] do
        {:ok, lv, _html} = live(limited_conn(build_conn(), limiter), ~p"/users/log-in")
        assert submit_magic(lv, email) =~ @requested
        flush_emails()
        before = tokens()

        html = submit_magic(lv, String.upcase(email))

        assert html =~ ~r/Too many sign-in requests\. Try again in \d+ seconds?\./
        refute html =~ @requested
        assert email_value?(lv, String.upcase(email))
        assert tokens() == before
        assert_no_email_sent()
      end
    end

    test "registration sign-in resend and email change share auth limits" do
      %{limiter: limiter} = start_limiter(auth_destination: {2, 60_000}, auth_ip: {4, 60_000})
      account = user_fixture()
      signed_in = build_conn() |> limited_conn(limiter) |> log_in_user(account)
      shared = unique_user_email()

      # The destination bucket: email change, then signup with other casing, spend it.
      {:ok, settings, _html} = live(signed_in, ~p"/users/settings")

      assert settings |> form("#email_form", %{"user" => %{"email" => shared}}) |> render_submit() =~
               "A link to confirm your email"

      {:ok, register, _html} = live(limited_conn(build_conn(), limiter), ~p"/users/register")

      assert {:error, {:live_redirect, _}} =
               register
               |> form("#registration_form",
                 user: %{"handle" => "Shared_Bucket", "email" => String.upcase(shared)}
               )
               |> render_submit()

      {:ok, lv, _html} = live(limited_conn(build_conn(), limiter), ~p"/users/log-in")
      assert submit_magic(lv, shared) =~ "Too many sign-in requests"

      # The IP bucket: reauthentication and sign-in spend the rest; denials spent nothing.
      {:ok, reauth, _html} = live(signed_in, ~p"/users/log-in")
      assert submit_magic(reauth, account.email) =~ @requested
      assert submit_magic(lv, unique_user_email()) =~ @requested
      assert submit_magic(lv, unique_user_email()) =~ "Too many sign-in requests"
    end

    test "capacity, missing identity and invalid addresses fail closed", %{conn: conn} do
      %{limiter: full} = start_limiter(capacity: [auth: 2])
      :ok = Tips.AdmissionLimiter.check_auth("other@example.com", {192, 0, 2, 1}, full)
      no_peer = put_private(conn, :live_view_connect_info, %{})
      email = user_fixture().email
      flush_emails()
      before = tokens()

      for {conn, email, feedback} <- [
            {limited_conn(build_conn(), full), email,
             ~r/Sign-in is busy right now\. Try again in \d+ seconds?\./},
            {no_peer, email, ~r/couldn&#39;t identify your connection/},
            {conn, "control\u0001char@example.com", ~r/is invalid/}
          ] do
        {:ok, lv, _html} = live(conn, ~p"/users/log-in")

        html = submit_magic(lv, email)

        assert html =~ feedback
        refute html =~ @requested
        assert tokens() == before
        assert_no_email_sent()
      end
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

    test "a forged address cannot replace the account's own address", %{conn: conn, user: user} do
      flush_emails()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      forged = %{"user" => %{"email" => "other-review@example.com"}}

      for _attempt <- 1..2 do
        assert render_submit(lv, "submit_magic", forged) =~ @requested
        assert email_value?(lv, user.email)
        assert_email_sent(to: user.email)
      end
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
