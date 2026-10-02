defmodule TipsWeb.UserSessionControllerTest do
  use TipsWeb.ConnCase, async: true

  import Ecto.Query
  import Swoosh.TestAssertions
  import Tips.AccountsFixtures

  alias Tips.Accounts
  alias Tips.Accounts.UserToken
  alias Tips.Repo

  @remember_me_cookie "_tips_web_user_remember_me"

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

  describe "family revocation through real cookies" do
    test "late renewal cookies cannot sign back in after logout", %{conn: conn, user: user} do
      browser = log_in_with_magic_link(conn, user, %{"remember_me" => "true"})
      other_browser = log_in_with_magic_link(build_conn(), user)
      initial = get_session(browser, :user_token)
      family = family(initial)
      backdate(initial, -7, :day)

      # Two responses renew the same cookies; the browser keeps one and logs out.
      kept = get(browser, ~p"/")
      late = get(browser, ~p"/")
      kept_token = get_session(kept, :user_token)
      late_token = get_session(late, :user_token)
      assert Enum.uniq([initial, kept_token, late_token]) == [initial, kept_token, late_token]
      assert [^family, ^family] = [family(kept_token), family(late_token)]
      %{value: late_remember_me} = late.resp_cookies[@remember_me_cookie]

      logged_out = delete(kept, ~p"/users/log-out")
      assert redirected_to(logged_out) == ~p"/"

      # The late response arrives after logout and restores its cookies.
      for stale <- [late, browser, remember_me_only(late_remember_me)] do
        replay = get(stale, ~p"/users/settings")
        assert redirected_to(replay) == ~p"/users/log-in"
        refute replay.assigns.current_scope
      end

      assert Repo.all_by(UserToken, session_family_id: family) == []

      for token <- [initial, kept_token, late_token] do
        refute Accounts.get_user_by_session_token(token)
      end

      assert other_browser |> get(~p"/users/settings") |> html_response(200) =~ user.email
      assert Accounts.get_user_by_session_token(get_session(other_browser, :user_token))
    end

    test "valid account switch revokes old family and preserves another browser", %{
      conn: conn,
      user: user
    } do
      new_user = user_fixture()
      browser = log_in_with_magic_link(conn, user, %{"remember_me" => "true"})
      other_browser = log_in_with_magic_link(build_conn(), user)
      old_token = get_session(browser, :user_token)
      old_family = family(old_token)
      {:ok, late_sibling} = Accounts.renew_user_session_token(user, old_token)
      %{value: old_remember_me} = browser.resp_cookies[@remember_me_cookie]
      TipsWeb.Endpoint.subscribe("users_sessions:#{old_family}")

      switched = log_in_with_magic_link(browser, new_user)

      assert redirected_to(switched) == ~p"/users/settings"
      new_token = get_session(switched, :user_token)
      refute family(new_token) == old_family
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert Repo.all_by(UserToken, session_family_id: old_family) == []

      for token <- [old_token, late_sibling] do
        refute Accounts.get_user_by_session_token(token)
      end

      for stale <- [browser, remember_me_only(old_remember_me)] do
        assert stale |> get(~p"/users/settings") |> redirected_to() == ~p"/users/log-in"
      end

      settings = switched |> get(~p"/users/settings") |> html_response(200)
      assert settings =~ new_user.email
      refute settings =~ user.email
      assert other_browser |> get(~p"/users/settings") |> html_response(200) =~ user.email
    end

    test "invalid expired or replayed switch proof leaves the old account signed in", %{
      conn: conn,
      user: user
    } do
      new_user = user_fixture()
      browser = log_in_with_magic_link(conn, user)
      token = get_session(browser, :user_token)
      {expired, expired_hash} = generate_user_magic_link_token(new_user)
      backdate(expired_hash, -15, :minute)
      {replayed, _} = generate_user_magic_link_token(new_user)
      log_in_with_magic_link(build_conn(), new_user, %{}, replayed)
      tokens = all_tokens()

      for proof <- ["invalid", expired, replayed] do
        rejected = post(browser, ~p"/users/log-in", %{"user" => %{"token" => proof}})

        assert redirected_to(rejected) == ~p"/users/log-in"

        assert Phoenix.Flash.get(rejected.assigns.flash, :error) ==
                 "The link is invalid or it has expired."

        assert get_session(rejected, :user_token) == token
        assert all_tokens() == tokens
        assert rejected |> get(~p"/users/settings") |> html_response(200) =~ user.email
      end
    end

    test "same-account reauthentication retains the family", %{conn: conn, user: user} do
      browser = log_in_with_magic_link(conn, user)
      token = get_session(browser, :user_token)
      stale = DateTime.add(DateTime.utc_now(:second), -1, :hour)
      override_token_authenticated_at(token, stale)
      TipsWeb.Endpoint.subscribe("users_sessions:#{family(token)}")

      reauthenticated = log_in_with_magic_link(browser, user)

      assert redirected_to(reauthenticated) == ~p"/users/settings"
      new_token = get_session(reauthenticated, :user_token)
      refute new_token == token
      assert family(new_token) == family(token)
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 50
      assert {session_user, _} = Accounts.get_user_by_session_token(new_token)
      assert Accounts.sudo_mode?(session_user)
      assert Accounts.get_user_by_session_token(token)
      assert reauthenticated |> get(~p"/users/settings") |> html_response(200) =~ user.email
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

  # A real login: posts a fresh (or the given) magic-link proof with the browser's cookies.
  defp log_in_with_magic_link(conn, user, params \\ %{}, proof \\ nil) do
    proof = proof || elem(generate_user_magic_link_token(user), 0)
    conn = post(conn, ~p"/users/log-in", %{"user" => Map.put(params, "token", proof)})
    assert get_session(conn, :user_token)
    conn
  end

  defp remember_me_only(signed_cookie) do
    put_req_cookie(build_conn(), @remember_me_cookie, signed_cookie)
  end

  defp family(token) do
    Repo.get_by!(UserToken, token: token, context: "session").session_family_id
  end

  defp backdate(token, amount, unit) do
    inserted_at = DateTime.add(DateTime.utc_now(:second), amount, unit)

    assert {1, nil} =
             Repo.update_all(from(t in UserToken, where: t.token == ^token),
               set: [inserted_at: inserted_at]
             )
  end

  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end
end
