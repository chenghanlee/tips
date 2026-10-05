defmodule TipsWeb.UserLive.SettingsTest do
  use TipsWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Tips.AccountsFixtures
  import Tips.AdmissionFixtures

  alias Tips.Accounts
  alias Tips.Accounts.{User, UserToken}
  alias Tips.{MailerTestAdapter, Repo}

  # Every test owns an isolated limiter and a fixed transport peer.
  setup %{conn: conn} do
    %{limiter: limiter} = start_limiter(auth_destination: {5, 60_000}, auth_ip: {20, 60_000})
    %{conn: limited_conn(conn, limiter)}
  end

  defp limited_conn(conn, limiter) do
    conn
    |> Plug.Test.init_test_session(%{"admission_limiter" => limiter})
    |> Plug.Test.put_peer_data(%{address: {198, 51, 100, 7}, port: 40_000, ssl_cert: nil})
  end

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Change Email"
      assert html =~ "Manage your account email address"
      refute has_element?(lv, "#password_form")
      refute has_element?(lv, "input[type=password]")
      refute String.downcase(html) =~ "password"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects if user is not in sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_user(user_fixture(),
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/users/settings")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "settings ignores forged handle changes", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_submit(%{"user" => %{"email" => unique_user_email(), "handle" => "Renamed"}})

      assert result =~ "A link to confirm your email"

      assert Tips.Repo.reload!(user).handle == user.handle
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "Change Email"
      assert result =~ "did not change"
    end

    test "delivery failure offers retry without claiming no message was sent",
         %{conn: conn, user: user} do
      MailerTestAdapter.script(:reject)
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      new_email = unique_user_email()

      html = lv |> form("#email_form", %{"user" => %{"email" => new_email}}) |> render_submit()

      assert html =~
               "We couldn&#39;t confirm that the confirmation link was sent to #{new_email}. " <>
                 "It may still arrive; if it doesn&#39;t, request it again. " <>
                 "Your sign-in email has not changed."

      refute html =~ "has been sent"
      assert has_element?(lv, ~s|#email_form input[name="user[email]"][value="#{new_email}"]|)
      assert [%UserToken{}] = change_email_tokens(user)
      assert Repo.reload!(user).email == user.email
      assert_received {:mail_attempt, _attempt}
      refute_received {:mail_attempt, _retry}
    end

    test "auth mail denial has no token or provider side effects; invalid changes are not charged",
         %{user: user} do
      %{limiter: limiter} = start_limiter(auth_ip: {1, 60_000})
      conn = build_conn() |> limited_conn(limiter) |> log_in_user(user)
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      submit = &(lv |> form("#email_form", %{"user" => %{"email" => &1}}) |> render_submit())

      # The fixture's confirmation mail.
      assert_email_sent(to: user.email)
      assert submit.(user.email) =~ "did not change"
      admitted = unique_user_email()
      assert submit.(admitted) =~ "A link to confirm your email"
      assert_email_sent(to: admitted)
      denied = unique_user_email()

      html = submit.(denied)

      assert html =~ ~r/Too many email change requests\. Try again in \d+ seconds?\./
      assert has_element?(lv, ~s|#email_form input[name="user[email]"][value="#{denied}"]|)
      assert [_admitted] = change_email_tokens(user)
      assert_no_email_sent()
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end

  describe "connected settings cannot send email after revocation without disconnect" do
    setup :mounted_settings

    test "a revoked family is redirected to log in and nothing is sent", %{
      conn: conn,
      lv: lv,
      user: user,
      token: token
    } do
      # Rows are deleted; the disconnect broadcast is never delivered to this socket.
      assert {:ok, [_family]} = Accounts.revoke_user_session_family(token)

      assert {:ok, conn} = lv |> submit_email() |> follow_redirect(conn, ~p"/users/log-in")

      assert conn.resp_body =~ "You must log in to access this page."
      assert change_email_tokens(user) == []
    end

    test "a current session still sends the confirmation link", %{lv: lv, user: user} do
      assert submit_email(lv) =~ "A link to confirm your email"
      assert [%UserToken{}] = change_email_tokens(user)
      assert Accounts.get_user_by_email(user.email)
    end
  end

  describe "expired/deleted/switched account cannot perform privileged work on an existing socket" do
    setup :mounted_settings

    test "expired session", %{lv: lv, user: user, token: token} do
      Repo.update_all(from(t in UserToken, where: t.token == ^token),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -60, :day)]
      )

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = submit_email(lv)
      assert change_email_tokens(user) == []
    end

    test "deleted account", %{lv: lv, user: user} do
      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [deleted_at: DateTime.utc_now(:second), handle: nil, email: nil]
      )

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = submit_email(lv)
      assert change_email_tokens(user) == []
    end

    test "account switch in the same browser", %{conn: conn, lv: lv, user: user} do
      other = user_fixture()
      {proof, _hashed} = generate_user_magic_link_token(other)

      switched = post(conn, ~p"/users/log-in", %{"user" => %{"token" => proof}})

      assert {%User{id: other_id}, _} =
               Accounts.get_user_by_session_token(get_session(switched, :user_token))

      assert other_id == other.id

      # The old tab is still connected and submits as the first account.
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = submit_email(lv)
      assert change_email_tokens(user) == []
      assert change_email_tokens(other) == []
    end

    test "client identity in the event cannot choose another account", %{lv: lv, user: user} do
      other = user_fixture()
      other_token = Accounts.generate_user_session_token(other)
      %UserToken{id: other_token_id} = Repo.get_by!(UserToken, token: other_token)

      forged = %{
        "user" => %{"email" => unique_user_email(), "id" => other.id},
        "user_id" => other.id,
        "user_token" => Base.url_encode64(other_token),
        "session_ref" => %{"token_id" => other_token_id, "user_id" => other.id}
      }

      assert lv |> element("#email_form") |> render_submit(forged) =~
               "A link to confirm your email"

      assert [%UserToken{context: context}] = change_email_tokens(user)
      assert context == "change:#{user.email}"
      assert change_email_tokens(other) == []
    end
  end

  describe "stale sudo redirects without a crash" do
    setup :mounted_settings

    test "authentication older than the sudo window", %{
      conn: conn,
      lv: lv,
      user: user,
      token: token
    } do
      override_token_authenticated_at(
        token,
        DateTime.add(DateTime.utc_now(:second), -21, :minute)
      )

      ref = Process.monitor(lv.pid)

      assert {:ok, conn} = lv |> submit_email() |> follow_redirect(conn, ~p"/users/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
      assert change_email_tokens(user) == []
      assert_receive {:DOWN, ^ref, :process, _pid, {:shutdown, _redirect}}
    end
  end

  describe "fresh admission protects email confirmation" do
    setup :mounted_settings

    setup %{user: user} do
      email = unique_user_email()

      confirmation =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{confirmation: confirmation, email: email}
    end

    test "an existing socket cannot confirm after revocation", %{
      lv: lv,
      user: user,
      token: token,
      confirmation: confirmation
    } do
      assert {:ok, [_family]} = Accounts.revoke_user_session_family(token)

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live_redirect(lv, to: ~p"/users/settings/confirm-email/#{confirmation}")

      assert Repo.reload!(user).email == user.email
    end

    test "an existing socket cannot confirm with stale sudo", %{
      conn: conn,
      lv: lv,
      user: user,
      token: token,
      confirmation: confirmation
    } do
      override_token_authenticated_at(
        token,
        DateTime.add(DateTime.utc_now(:second), -11, :minute)
      )

      assert {:ok, conn} =
               lv
               |> live_redirect(to: ~p"/users/settings/confirm-email/#{confirmation}")
               |> follow_redirect(conn, ~p"/users/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
      assert Repo.reload!(user).email == user.email
    end

    test "a deleted account cannot confirm from a new request", %{
      conn: conn,
      user: user,
      confirmation: confirmation
    } do
      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [deleted_at: DateTime.utc_now(:second), handle: nil, email: nil]
      )

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/users/settings/confirm-email/#{confirmation}")

      assert %User{email: nil} = Repo.reload!(user)
      assert [%UserToken{}] = change_email_tokens(user)
    end

    test "a current session confirms from an existing socket", %{
      lv: lv,
      user: user,
      confirmation: confirmation,
      email: email
    } do
      assert {:error, {:live_redirect, %{to: "/users/settings"}}} =
               live_redirect(lv, to: ~p"/users/settings/confirm-email/#{confirmation}")

      assert Repo.reload!(user).email == email
    end
  end

  describe "rendered credential privacy" do
    setup :mounted_settings

    test "no bearer or reference is rendered", %{
      lv: lv,
      html: html,
      token: token
    } do
      for rendered <- [html, render(lv), submit_email(lv)] do
        refute rendered =~ "SessionRef"
        refute rendered =~ "token_id"
        refute rendered =~ Base.encode64(token)
        refute rendered =~ Base.url_encode64(token, padding: false)
      end
    end
  end

  defp mounted_settings(%{conn: conn}) do
    user = user_fixture()
    conn = log_in_user(conn, user)
    {:ok, lv, html} = live(conn, ~p"/users/settings")
    %{conn: conn, user: user, token: get_session(conn, :user_token), lv: lv, html: html}
  end

  defp submit_email(lv) do
    lv |> form("#email_form", %{"user" => %{"email" => unique_user_email()}}) |> render_submit()
  end

  defp change_email_tokens(user) do
    Repo.all(from t in UserToken, where: t.user_id == ^user.id and like(t.context, "change:%"))
  end
end
