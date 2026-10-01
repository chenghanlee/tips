defmodule TipsWeb.UserSessionControllerTest do
  use TipsWeb.ConnCase, async: true

  import Swoosh.TestAssertions
  import Tips.AccountsFixtures

  alias Tips.Accounts
  alias Tips.Accounts.UserToken
  alias Tips.Repo

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), user: user_fixture()}
  end

  describe "POST /users/log-in - password credentials" do
    test "password credentials cannot authenticate or issue a session", %{conn: conn, user: user} do
      flush_emails()
      tokens = all_tokens()

      for email <- [user.email, "unknown@example.com"] do
        conn =
          post(conn, ~p"/users/log-in", %{
            "user" => %{"email" => email, "password" => "hello world!", "remember_me" => "true"}
          })

        assert redirected_to(conn) == ~p"/users/log-in"

        assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
                 "The link is invalid or it has expired."

        refute get_session(conn, :user_token)
        refute conn.resp_cookies["_tips_web_user_remember_me"]
        assert all_tokens() == tokens
        assert_no_email_sent()
      end
    end
  end

  describe "POST /users/log-in - malformed input" do
    for {label, params} <- [
          {"missing user", %{}},
          {"non-map user", %{"user" => "bad"}},
          {"null token", %{"user" => %{"token" => nil}}},
          {"map token", %{"user" => %{"token" => %{"bad" => "value"}}}},
          {"list token", %{"user" => %{"token" => ["bad"]}}},
          {"invalid Base64 token", %{"user" => %{"token" => "%"}}},
          {"invalid Base64 length", %{"user" => %{"token" => "a"}}}
        ] do
      @params params
      test "rejects #{label} without session, token or mail", %{conn: conn} do
        flush_emails()
        tokens = all_tokens()
        conn = post(conn, ~p"/users/log-in", @params)

        assert redirected_to(conn) == ~p"/users/log-in"

        assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
                 "The link is invalid or it has expired."

        refute get_session(conn, :user_token)
        assert all_tokens() == tokens
        assert_no_email_sent()
      end
    end
  end

  describe "POST /users/update-password" do
    test "removed password update route cannot change account or session", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)
      session_token = get_session(conn, :user_token)
      tokens = all_tokens()

      conn =
        post(conn, "/users/update-password", %{
          "user" => %{
            "email" => user.email,
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        })

      assert response(conn, 404)
      assert get_session(conn, :user_token) == session_token
      assert Accounts.get_user!(user.id) == user
      assert all_tokens() == tokens
      assert {%{id: id}, _inserted_at} = Accounts.get_user_by_session_token(session_token)
      assert id == user.id
    end
  end

  describe "POST /users/log-in - magic link" do
    test "logs the user in", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token, "remember_me" => "true"}
        })

      assert conn.resp_cookies["_tips_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{"user" => %{"token" => token}})

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "confirms unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)
      refute user.confirmed_at

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "User confirmed successfully."

      assert Accounts.get_user!(user.id).confirmed_at

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "redirects to login page when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => "invalid"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The link is invalid or it has expired."

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end

  defp all_tokens, do: UserToken |> Repo.all() |> Enum.sort_by(& &1.id)

  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end
end
