defmodule TipsWeb.AdmissionLogPrivacyTest do
  @moduledoc """
  Debug-level log evidence for #47: the session bearer and the private row
  reference never reach the logs on the admission paths.

  Not async: it lowers the global Logger level while it captures.
  """
  use TipsWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures

  alias Tips.Accounts
  alias Tips.Accounts.{SessionRef, UserToken}
  alias Tips.Repo

  setup %{conn: conn} do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

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
    log = capture_log(fn -> assert conn |> get(~p"/users/settings") |> html_response(200) end)

    assert log =~ "GET /users/settings"
    assert_private(log, context)
  end

  test "a connected settings mount logs the view, not its session", %{conn: conn} = context do
    log = capture_log(fn -> assert {:ok, _lv, _html} = live(conn, ~p"/users/settings") end)

    assert log =~ "MOUNT TipsWeb.UserLive.Settings"
    assert_private(log, context)
  end

  test "privileged readmission logs the event and its write, not the row binding",
       %{conn: conn} = context do
    {:ok, lv, _html} = live(conn, ~p"/users/settings")

    log =
      capture_log(fn ->
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
      capture_log(fn ->
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
      with_log(fn ->
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
      with_log(fn -> post(build_conn(), ~p"/users/log-in", %{"user" => %{"token" => proof}}) end)

    assert log =~ "POST /users/log-in"
    assert log =~ "[FILTERED]"
    refute log =~ proof, "log contains the magic-link proof"

    assert_private(log, %{
      token: get_session(conn, :user_token),
      ref: %SessionRef{token_id: 0, user_id: 0}
    })
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
