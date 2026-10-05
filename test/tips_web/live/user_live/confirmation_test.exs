defmodule TipsWeb.UserLive.ConfirmationTest do
  use TipsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures

  alias Plug.Conn.Query
  alias Tips.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), confirmed_user: user_fixture()}
  end

  describe "Confirm user" do
    test "renders login page for already logged in user", %{conn: conn, confirmed_user: user} do
      conn = log_in_user(conn, user)

      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/users/log-in/#{token}")
      refute html =~ "Confirm my account"
      assert html =~ "Log in"
    end

    test "confirms the given token once", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, lv, html} = live(conn, ~p"/users/log-in/#{token}")

      assert has_element?(
               lv,
               ~s|#confirmation_form button[name="user[remember_me]"][value="true"]|,
               "Confirm and stay logged in"
             )

      refute has_element?(lv, "input[type=password]")
      refute String.downcase(html) =~ "password"

      form = form(lv, "#confirmation_form", %{"user" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "User confirmed successfully"

      assert Accounts.get_user!(user.id).confirmed_at
      # we are logged in now
      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/users/log-in/#{token}")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "logs confirmed user in without changing confirmed_at", %{
      conn: conn,
      confirmed_user: user
    } do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, lv, html} = live(conn, ~p"/users/log-in/#{token}")

      assert has_element?(
               lv,
               ~s|#login_form button[name="user[remember_me]"][value="true"]|,
               "Keep me logged in on this device"
             )

      refute has_element?(lv, "#confirmation_form")
      refute has_element?(lv, "input[type=password]")
      refute String.downcase(html) =~ "password"

      form = form(lv, "#login_form", %{"user" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Welcome back!"

      assert Accounts.get_user!(user.id).confirmed_at == user.confirmed_at

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/users/log-in/#{token}")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "expired registration cannot establish a session and offers restart signup", %{
      conn: conn,
      unconfirmed_user: user
    } do
      token = extract_user_token(&Accounts.deliver_login_instructions(user, &1))
      set_registration_deadline(user, 0)

      {:ok, lv, html} =
        live(conn, ~p"/users/log-in/#{token}")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "Magic link is invalid or it has expired"
      assert html =~ "signed up more than seven days ago without confirming, register again"
      refute html =~ "Confirm and stay logged in"
      assert has_element?(lv, ~s|a[href="/users/register"]|)
      refute Accounts.get_user!(user.id).confirmed_at
    end

    # Each form and button carries the link's destination through submission, its
    # rerender and the controller redirect, in a browser without the original session.
    for {form, user_key} <- [
          {"#confirmation_form", :unconfirmed_user},
          {"#login_form", :confirmed_user}
        ],
        remember_me? <- [true, false] do
      @form form
      @user_key user_key
      @remember_me remember_me?
      test "#{form} #{if remember_me?, do: "remember-me", else: "session-only"} returns to the link's destination",
           context do
        user = Map.fetch!(context, @user_key)
        token = extract_user_token(&Accounts.deliver_login_instructions(user, &1))

        {:ok, lv, _html} = live(build_conn(), ~p"/users/log-in/#{token}?return_to=/reviews/9")

        form = form(lv, @form)
        render_submit(form)
        assert has_element?(lv, ~s|#{@form} input[name="user[return_to]"][value="/reviews/9"]|)

        conn =
          if @remember_me,
            do: post_with_remember_me(lv, @form),
            else: follow_trigger_action(form, build_conn())

        assert redirected_to(conn) == "/reviews/9"
        assert get_session(conn, :user_token)
        assert !!conn.resp_cookies["_tips_web_user_remember_me"] == @remember_me
      end
    end

    test "an unsafe or malformed link destination is dropped and sign-in still works", %{
      confirmed_user: user
    } do
      for query <- ["return_to=%2F%2Fevil.example", "return_to[to]=%2Freviews%2F9"] do
        token = extract_user_token(&Accounts.deliver_login_instructions(user, &1))
        {:ok, lv, _html} = live(build_conn(), "/users/log-in/#{token}?#{query}")

        refute has_element?(lv, ~s|input[name="user[return_to]"]|), query
        form = form(lv, "#login_form")
        render_submit(form)
        assert redirected_to(follow_trigger_action(form, build_conn())) == ~p"/", query
      end
    end

    test "without a valid link destination the browser's own session destination is carried", %{
      confirmed_user: user
    } do
      token = extract_user_token(&Accounts.deliver_login_instructions(user, &1))
      conn = init_test_session(build_conn(), %{"user_return_to" => "/users/settings"})

      {:ok, lv, _html} = live(conn, "/users/log-in/#{token}?return_to=%2F%2Fevil.example")

      assert has_element?(
               lv,
               ~s|#login_form input[name="user[return_to]"][value="/users/settings"]|
             )
    end

    # A rejected link sends the reader to request another; only a safe destination goes along.
    for {label, query, session, log_in} <- [
          {"keeps a safe destination", "return_to=%2Freviews%2F9", %{},
           "/users/log-in?return_to=%2Freviews%2F9"},
          {"keeps the session's destination behind an unsafe one", "return_to=%2F%2Fevil.example",
           %{"user_return_to" => "/users/settings"},
           "/users/log-in?return_to=%2Fusers%2Fsettings"},
          {"drops an unsafe destination", "return_to=%2F%2Fevil.example", %{}, "/users/log-in"},
          {"drops a malformed destination", "return_to[to]=%2Freviews%2F9", %{}, "/users/log-in"}
        ] do
      @query query
      @session session
      @log_in log_in
      test "a used link #{label} on the way to log in", %{confirmed_user: user} do
        token = extract_user_token(&Accounts.deliver_login_instructions(user, &1))
        assert {:ok, _} = Accounts.login_user_by_magic_link(token, nil)
        conn = init_test_session(build_conn(), @session)

        assert {:error, {:live_redirect, %{to: @log_in}}} =
                 live(conn, "/users/log-in/#{token}?#{@query}")
      end
    end

    test "a link used elsewhere after the form rendered keeps the destination", %{
      confirmed_user: user
    } do
      token = extract_user_token(&Accounts.deliver_login_instructions(user, &1))
      {:ok, lv, _html} = live(build_conn(), ~p"/users/log-in/#{token}?return_to=/reviews/9")
      form = form(lv, "#login_form")
      render_submit(form)
      assert {:ok, _} = Accounts.login_user_by_magic_link(token, nil)

      conn = follow_trigger_action(form, build_conn())

      assert redirected_to(conn) == "/users/log-in?return_to=%2Freviews%2F9"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "The link is invalid"
      refute get_session(conn, :user_token)
    end

    test "raises error for invalid token", %{conn: conn} do
      {:ok, _lv, html} =
        live(conn, ~p"/users/log-in/invalid-token")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end
  end

  # What the browser posts for the named remember-me button: the form's rendered fields
  # plus the button's name and value. The trigger action in LiveViewTest omits submitters.
  defp post_with_remember_me(lv, form) do
    doc = lv |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(form)
    [action] = LazyHTML.attribute(doc, "action")

    fields =
      for node <- LazyHTML.query(doc, ~s|input[type="hidden"], button[name="user[remember_me]"]|),
          do: {hd(LazyHTML.attribute(node, "name")), hd(LazyHTML.attribute(node, "value"))}

    post(build_conn(), action, Query.decode(URI.encode_query(fields)))
  end
end
