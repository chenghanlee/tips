defmodule TipsWeb.AdmissionLogPrivacyTest do
  @moduledoc """
  Debug-level log evidence for #47: the session bearer and the private row
  reference never reach the logs on the admission paths.

  Not async: `logged/2` lowers the global Logger level while it captures, and
  restores it before returning.
  """
  use TipsWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures

  alias Phoenix.LiveDashboard.PageLive
  alias Tips.Accounts
  alias Tips.Accounts.{SessionRef, UserToken}
  alias Tips.Repo

  # A LiveView outside `TipsWeb.live_view/0`, as LiveDashboard's pages are.
  defmodule PlainLive do
    use Phoenix.LiveView

    def mount(_params, _session, socket), do: {:ok, socket}
    def render(assigns), do: ~H"<p id=\"plain\">plain</p>"
  end

  # Fixtures run at the configured level; only `logged/2` lowers it.
  setup %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    token = get_session(conn, :user_token)
    %UserToken{id: token_id} = Repo.get_by!(UserToken, token: token)

    %{
      conn: conn,
      user: user,
      token: token,
      ref: %SessionRef{token_id: token_id, user_id: user.id}
    }
  end

  test "controller bearer admission logs the request, not the bearer", %{conn: conn} = context do
    log = logged(fn -> assert conn |> get(~p"/users/settings") |> html_response(200) end)

    assert log =~ "GET /users/settings"
    assert_private(log, context)
  end

  test "a connected settings mount logs the view, not its session", %{conn: conn} = context do
    log = logged(fn -> assert {:ok, _lv, _html} = live(conn, ~p"/users/settings") end)

    assert log =~ "MOUNT TipsWeb.UserLive.Settings"
    assert_private(log, context)
  end

  test "privileged readmission logs the event and its write, not the row binding",
       %{conn: conn} = context do
    {:ok, lv, _html} = live(conn, ~p"/users/settings")

    log =
      logged(fn ->
        assert lv
               |> form("#email_form", %{"user" => %{"email" => unique_user_email()}})
               |> render_submit() =~ "A link to confirm your email"
      end)

    assert log =~ ~s(HANDLE EVENT "update_email" in TipsWeb.UserLive.Settings)
    assert log =~ ~s(INSERT INTO "users_tokens")

    assert_private(log, context)
  end

  test "credential-shaped event input is not logged",
       %{conn: conn, token: token, ref: ref} = context do
    {:ok, lv, _html} = live(conn, ~p"/users/settings")
    encoded = Base.url_encode64(token, padding: false)

    forged = %{
      "user" => %{"email" => "with spaces"},
      "user_token" => encoded,
      "session_ref" => %{"token_id" => ref.token_id, "user_id" => ref.user_id}
    }

    log =
      logged(fn ->
        for event <- [&render_change/2, &render_submit/2] do
          assert lv |> element("#email_form") |> event.(forged) =~ "must have the @ sign"
        end
      end)

    assert log =~ ~s(HANDLE EVENT "validate_email" in TipsWeb.UserLive.Settings)
    assert log =~ ~s(HANDLE EVENT "update_email" in TipsWeb.UserLive.Settings)
    refute log =~ encoded, "event log contains the submitted bearer"
    refute log =~ "session_ref", "event log contains the submitted reference"
    assert_private(log, context)
  end

  test "renewal and logout log their writes, not the bearer",
       %{conn: conn, user: user} = context do
    backdated = DateTime.add(DateTime.utc_now(:second), -7, :day)
    Repo.update_all(UserToken, set: [inserted_at: backdated])

    {renewed, log} =
      logged_result(fn ->
        renewed = get(conn, ~p"/users/settings")
        assert html_response(renewed, 200)
        assert renewed |> delete(~p"/users/log-out") |> redirected_to() == ~p"/"
        renewed
      end)

    successor = get_session(renewed, :user_token)
    refute successor == context.token
    assert Accounts.get_user_by_session_token(successor) == nil
    assert log =~ ~s(DELETE FROM "users_tokens")
    assert_private(log, context)

    assert_private(log, %{
      context
      | token: successor,
        ref: %SessionRef{token_id: 0, user_id: user.id}
    })
  end

  test "magic-link log-in filters the proof and never logs the issued bearer", %{user: user} do
    {proof, _hashed} = generate_user_magic_link_token(user)

    {conn, log} =
      logged_result(fn ->
        post(build_conn(), ~p"/users/log-in", %{"user" => %{"token" => proof}})
      end)

    assert log =~ "POST /users/log-in"
    assert log =~ "[FILTERED]"
    refute log =~ proof, "log contains the magic-link proof"

    assert_private(log, %{
      token: get_session(conn, :user_token),
      ref: %SessionRef{token_id: 0, user_id: 0}
    })
  end

  describe "credential URL segments" do
    for level <- [:info, :debug] do
      test "magic-link GET at #{level} logs the route, not the proof", %{user: user} do
        {proof, _hashed} = generate_user_magic_link_token(user)

        log =
          logged(unquote(level), fn ->
            assert build_conn() |> get(~p"/users/log-in/#{proof}") |> html_response(200)
          end)

        assert log =~ "GET /users/log-in/:token"
        assert log =~ "Sent 200 in"
        refute log =~ proof, "log contains the magic-link proof"
        # The page only rendered; the logged request left the proof usable.
        assert {:ok, %{session_token: _}} = Accounts.login_user_by_magic_link(proof)
      end

      test "email-confirmation GET at #{level} logs the route, not the token",
           %{conn: conn, user: user} = context do
        email = unique_user_email()

        confirmation =
          extract_user_token(fn url ->
            Accounts.deliver_user_update_email_instructions(
              %{user | email: email},
              user.email,
              url
            )
          end)

        log =
          logged(unquote(level), fn ->
            assert conn
                   |> get(~p"/users/settings/confirm-email/#{confirmation}")
                   |> redirected_to() == ~p"/users/settings"
          end)

        assert log =~ "GET /users/settings/confirm-email/:token"
        assert log =~ "Sent 302 in"
        refute log =~ confirmation, "log contains the email-change token"
        assert Repo.reload!(user).email == email
        assert_private(log, context)
      end
    end

    test "connected mounts on credential routes log the view only", %{conn: conn, user: user} do
      {proof, _hashed} = generate_user_magic_link_token(user)

      log =
        logged(fn ->
          assert {:ok, _lv, _html} = live(build_conn(), ~p"/users/log-in/#{proof}")
        end)

      assert log =~ "MOUNT TipsWeb.UserLive.Confirmation"
      refute log =~ proof, "log contains the magic-link proof"

      log = logged(fn -> assert conn |> get(~p"/users/log-in/#{proof}") |> html_response(200) end)
      refute log =~ proof, "log contains the magic-link proof"
    end

    test "malformed and unrouted paths neither crash nor detach the request logger", %{
      user: user
    } do
      for path <- [
            "/users/log-in/%ZZ",
            "/users/log-in/%00",
            "/no/such/route",
            "/users/log-in/a/b"
          ] do
        assert %Plug.Conn{status: status} = get(build_conn(), path)
        assert status < 500
      end

      {proof, _hashed} = generate_user_magic_link_token(user)
      log = logged(:info, fn -> get(build_conn(), ~p"/users/log-in/#{proof}") end)
      assert log =~ "GET /users/log-in/:token"
      refute log =~ proof, "log contains the magic-link proof"
    end

    test "other paths keep the framework's request lines", %{conn: conn} do
      log = logged(:info, fn -> assert conn |> get(~p"/users/settings") |> html_response(200) end)

      assert log =~ "GET /users/settings"
      assert log =~ "Sent 200 in"
      refute log =~ ":token"
    end
  end

  test "a LiveView outside the TipsWeb macro does not log its session",
       %{conn: conn, token: token} = context do
    assert PlainLive.__live__().log == PageLive.__live__().log

    log =
      logged(fn ->
        assert {:ok, _lv, _html} =
                 live_isolated(conn, PlainLive, session: %{"user_token" => token})
      end)

    assert log =~ "MOUNT TipsWeb.AdmissionLogPrivacyTest.PlainLive"
    refute log =~ "Session:"
    assert_private(log, context)
  end

  # Captures `fun`'s log at `level`, then restores the previous level.
  defp logged(level \\ :debug, fun), do: fun |> logged_result(level) |> elem(1)

  defp logged_result(fun, level \\ :debug) do
    previous = Logger.level()
    Logger.configure(level: level)

    try do
      with_log(fun)
    after
      Logger.configure(level: previous)
    end
  end

  # Failure messages name the leak; they never print the log or the values.
  defp assert_private(log, %{token: token, ref: %SessionRef{token_id: token_id, user_id: user_id}}) do
    bearer_forms = [
      token |> binary_part(0, 8) |> :binary.bin_to_list() |> Enum.join(", "),
      Base.encode64(token),
      Base.url_encode64(token, padding: false),
      Base.encode16(token, case: :lower)
    ]

    refute Enum.any?(bearer_forms, &(log =~ &1)), "log contains the session bearer"

    refute log =~ ~r/\[#{token_id}, #{user_id}[,\]]/,
           "log contains the private row reference as query parameters"

    refute log =~ "SessionRef", "log contains an inspected session reference"
  end
end
