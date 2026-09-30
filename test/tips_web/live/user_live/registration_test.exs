defmodule TipsWeb.UserLive.RegistrationTest do
  use TipsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Tips.AccountsFixtures
  import Tips.AdmissionFixtures

  alias Tips.Accounts.{User, UserToken}
  alias Tips.Repo

  @peer {198, 51, 100, 7}
  @return_to "/editor/tips/new"
  @log_in_with_return "/users/log-in?return_to=%2Feditor%2Ftips%2Fnew"

  # Every test owns an isolated limiter and a fixed transport peer.
  setup %{conn: conn} do
    %{limiter: limiter} = start_limiter()
    %{conn: registration_conn(conn, limiter)}
  end

  defp registration_conn(conn, limiter, session \\ %{}) do
    conn
    |> Plug.Test.init_test_session(Map.put(session, "admission_limiter", limiter))
    |> Plug.Test.put_peer_data(%{address: @peer, port: 40_000, ssl_cert: nil})
  end

  defp submit(lv, attrs) do
    lv |> form("#registration_form", user: attrs) |> render_submit()
  end

  defp side_effects(email) do
    %{
      users: Repo.aggregate(User, :count),
      tokens: Repo.aggregate(UserToken, :count),
      user: Repo.get_by(User, email: email)
    }
  end

  defp field_value(lv, field) do
    lv
    |> element("#user_#{field}")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("value")
  end

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Register"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "Register"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "registration uses shared accessible fields and explains that the handle is fixed",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert [suggestion] = field_value(lv, :handle)
      assert suggestion =~ ~r/\A[a-z]+-\d{4}\z/
      assert has_element?(lv, "label[for=user_handle]", "Handle")
      assert has_element?(lv, "label[for=user_email]", "Email")
      assert has_element?(lv, "#user_handle[aria-describedby~=user_handle-help]")
      assert has_element?(lv, "#user_handle-help", "can't be changed")
    end
  end

  describe "handle suggestion" do
    test "editing or clearing a suggestion survives validation and recovery", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      [suggestion] = field_value(lv, :handle)

      lv
      |> element("#registration_form")
      |> render_change(user: %{"handle" => "my-own-handle", "email" => "partial"})

      assert field_value(lv, :handle) == ["my-own-handle"]

      lv
      |> element("#registration_form")
      |> render_change(user: %{"handle" => "", "email" => "partial@"})

      assert field_value(lv, :handle) in [[], [""]]
      refute render(lv) =~ suggestion

      html = submit(lv, %{"handle" => "", "email" => "partial@"})

      assert html =~ "can&#39;t be blank"
      assert field_value(lv, :handle) in [[], [""]]
      assert field_value(lv, :email) == ["partial@"]
      refute render(lv) =~ suggestion
    end
  end

  describe "register user" do
    test "creates an unconfirmed account, sends the link and keeps return_to", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register?return_to=#{@return_to}")
      email = unique_user_email()

      {:ok, _lv, html} =
        lv
        |> submit(%{"handle" => "Chosen_One", "email" => email})
        |> follow_redirect(conn, @log_in_with_return)

      assert html =~ ~r/An email was sent to .*, please access it to confirm your account/
      assert %User{handle: "Chosen_One", confirmed_at: nil} = Repo.get_by(User, email: email)

      assert_email_sent(fn sent ->
        assert sent.to == [{"", email}]
        assert sent.text_body =~ ~r{/users/log-in/[^\s?]+\?return_to=%2Feditor%2Ftips%2Fnew}
      end)
    end

    test "registered email offers sign in without changing the existing identity",
         %{conn: conn} do
      existing = user_fixture(%{handle: "Original", email: "taken@example.com"})
      assert_email_sent()
      {:ok, lv, _html} = live(conn, ~p"/users/register?return_to=#{@return_to}")

      html = submit(lv, %{"handle" => "Newcomer", "email" => " TAKEN@Example.com "})

      assert html =~ "already registered"
      assert has_element?(lv, ~s|#email-registered a[href="#{@log_in_with_return}"]|, "Sign in")
      assert field_value(lv, :handle) == ["Newcomer"]
      assert %User{handle: "Original", email: "taken@example.com"} = Repo.reload!(existing)
      refute Repo.get_by(User, handle: "Newcomer")
      assert_no_email_sent()
    end

    test "validation duplicate and limiter failures preserve both fields and allowed return_to" do
      %{limiter: limiter} = start_limiter(auth_ip: {1, 1_000})
      conn = registration_conn(build_conn(), limiter)
      insert_handle = unconfirmed_user_fixture(%{handle: "Claimed"}).handle
      {:ok, lv, _html} = live(conn, ~p"/users/register?return_to=#{@return_to}")

      # Validation failure: the limiter is not consulted.
      html = submit(lv, %{"handle" => "Keeper", "email" => "no-at-sign"})
      assert html =~ "must have the @ sign and no spaces"
      assert field_value(lv, :handle) == ["Keeper"]
      assert field_value(lv, :email) == ["no-at-sign"]
      assert has_element?(lv, ~s|a[href="#{@log_in_with_return}"]|, "Log in")

      # Duplicate handle: admitted, then the database constraint answers.
      email = unique_user_email()
      html = submit(lv, %{"handle" => String.upcase(insert_handle), "email" => email})
      assert html =~ "has already been taken"
      assert field_value(lv, :handle) == [String.upcase(insert_handle)]
      assert field_value(lv, :email) == [email]
      assert has_element?(lv, ~s|a[href="#{@log_in_with_return}"]|, "Log in")

      # Limiter failure: the single IP admission is spent.
      other = unique_user_email()
      html = submit(lv, %{"handle" => "Fresh_Handle", "email" => other})
      assert html =~ ~r/Too many sign-up attempts\. Try again in \d+ seconds?\./
      assert field_value(lv, :handle) == ["Fresh_Handle"]
      assert field_value(lv, :email) == [other]
      assert has_element?(lv, ~s|a[href="#{@log_in_with_return}"]|, "Log in")
      refute Repo.get_by(User, email: other)
    end

    test "external and malformed return destinations are discarded", %{conn: conn} do
      for bad <- [
            "https://evil.example/editor/tips/new",
            "//evil.example",
            "/\\evil.example",
            "/editor/tips/0/edit",
            "/editor/tips/1/edit/extra",
            "/%2F%2Fevil.example",
            "/editor/tips/new\n",
            "/users/settings",
            "editor/tips/new"
          ] do
        {:ok, lv, _html} = live(conn, "/users/register?" <> URI.encode_query(return_to: bad))

        assert has_element?(lv, ~s|main a[href="/users/log-in"]|, "Log in"),
               "kept #{inspect(bad)}"
      end

      # The session fallback passes the same validator.
      %{limiter: limiter} = start_limiter()

      for {stored, expected} <- [
            {"/editor/reviews/12/edit",
             "/users/log-in?return_to=%2Feditor%2Freviews%2F12%2Fedit"},
            {"/users/settings", "/users/log-in"}
          ] do
        conn = registration_conn(build_conn(), limiter, %{"user_return_to" => stored})
        {:ok, lv, _html} = live(conn, ~p"/users/register")
        assert has_element?(lv, ~s|main a[href="#{expected}"]|, "Log in")
      end
    end
  end

  describe "admission limits" do
    test "limiter denial prevents account token and mail side effects: rate and forged identity" do
      %{limiter: limiter} = start_limiter(auth_ip: {2, 60_000})

      for n <- 1..3 do
        conn =
          build_conn()
          |> registration_conn(limiter)
          |> put_req_header("x-forwarded-for", "203.0.113.#{n}")

        {:ok, lv, _html} =
          live(conn, ~p"/users/register", connect_params: %{"ip" => "10.0.0.#{n}"})

        email = "forged#{n}-#{System.unique_integer([:positive])}@example.com"
        before = side_effects(email)

        html =
          submit(lv, %{
            "handle" => "forged_#{n}_#{System.unique_integer([:positive])}",
            "email" => email
          })

        if n < 3 do
          assert_email_sent(to: email)
        else
          assert html =~ ~r/Too many sign-up attempts\. Try again in \d+ seconds?\./
          assert side_effects(email) == before
          assert %{user: nil} = before
          assert_no_email_sent()
        end
      end
    end

    test "limiter denial prevents account token and mail side effects: capacity" do
      %{limiter: limiter} = start_limiter(capacity: [auth: 2])
      # Another identity holds both auth rows.
      :ok = Tips.AdmissionLimiter.check_auth("other@example.com", {192, 0, 2, 1}, limiter)
      {:ok, lv, _html} = live(registration_conn(build_conn(), limiter), ~p"/users/register")
      email = unique_user_email()
      before = side_effects(email)

      html = submit(lv, %{"handle" => "Capacity_Case", "email" => email})

      assert html =~ ~r/Sign-up is busy right now\. Try again in \d+ seconds?\./
      assert field_value(lv, :email) == [email]
      assert side_effects(email) == before
      assert_no_email_sent()
    end

    test "limiter denial prevents account token and mail side effects: missing identity",
         %{conn: conn} do
      conn = put_private(conn, :live_view_connect_info, %{})
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()
      before = side_effects(email)

      html = submit(lv, %{"handle" => "No_Identity", "email" => email})

      assert html =~ "couldn&#39;t identify your connection"
      assert field_value(lv, :handle) == ["No_Identity"]
      assert side_effects(email) == before
      assert_no_email_sent()
    end
  end

  describe "limiter-invalid email" do
    test "an email the limiter rejects gets field feedback and no side effects", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = "control\u0001char@example.com"
      before = side_effects(email)

      html = submit(lv, %{"handle" => "Control_Case", "email" => email})

      assert html =~ "is invalid"
      assert field_value(lv, :handle) == ["Control_Case"]
      assert side_effects(email) == before
      assert_no_email_sent()
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Log in"
    end
  end
end
