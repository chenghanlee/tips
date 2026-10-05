defmodule Tips.Accounts.AuthMailTest do
  use Tips.DataCase, async: true

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import Tips.AccountsFixtures

  alias Tips.Accounts
  alias Tips.Accounts.{User, UserToken}
  alias Tips.MailerTestAdapter

  # Scheduling tolerance on top of the configured budget for elapsed-time assertions.
  @slack_ms 500

  defp budget_ms,
    do: Application.fetch_env!(:tips, Tips.Accounts.UserNotifier)[:delivery_budget_ms]

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp url(token), do: "https://tips.example/users/log-in/#{token}"

  defp token_contexts(user) do
    Repo.all(from t in UserToken, where: t.user_id == ^user.id, select: t.context)
  end

  for {label, script, category} <- [
        {"explicit rejection", :reject, :uncertain},
        {"timeout", :block, :timeout}
      ] do
    @script script
    @category category
    test "delivery failures preserve committed identity and token: #{label}" do
      user = user_fixture()
      new_email = unique_user_email()
      MailerTestAdapter.script(@script)

      assert {:error, {:delivery, @category}} = Accounts.deliver_login_instructions(user, &url/1)

      assert {:error, {:delivery, @category}} =
               Accounts.deliver_user_update_email_instructions(
                 %{user | email: new_email},
                 user.email,
                 &url/1
               )

      assert Enum.sort(token_contexts(user)) == Enum.sort(["login", "change:#{user.email}"])

      assert %User{email: email, handle: handle, confirmed_at: confirmed_at} = Repo.reload!(user)
      assert {email, handle, confirmed_at} == {user.email, user.handle, user.confirmed_at}

      # One attempt per request; nothing retries.
      assert_received {:mail_attempt, _first}
      assert_received {:mail_attempt, _second}
      refute_received {:mail_attempt, _third}
    end
  end

  test "delivery is outside the transaction and bounded without retry" do
    user = user_fixture()
    MailerTestAdapter.script(:block)
    started = now_ms()

    caller = Task.async(fn -> Accounts.deliver_login_instructions(user, &url/1) end)

    assert_receive {:mail_attempt, attempt}, budget_ms()
    # The token is committed and the connection free while the provider call runs.
    assert token_contexts(user) == ["login"]
    assert Process.alive?(attempt)

    assert {:error, {:delivery, :timeout}} = Task.await(caller)
    assert now_ms() - started <= budget_ms() + @slack_ms
    refute Process.alive?(attempt)
    refute_received {:mail_attempt, _retry}
  end

  test "an attempt whose requester dies stops at the deadline and does not restart" do
    user = user_fixture()
    MailerTestAdapter.script(:block)
    started = now_ms()

    {:ok, owner} = Task.start(fn -> Accounts.deliver_login_instructions(user, &url/1) end)

    assert_receive {:mail_attempt, attempt}, budget_ms()
    ref = Process.monitor(attempt)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^ref, :process, ^attempt, _reason}, budget_ms() + @slack_ms
    assert now_ms() - started <= budget_ms() + @slack_ms
    refute_received {:mail_attempt, _restart}
  end

  for {kind, script} <- [
        raise: {:raise, "SECRET-MARKER raised by the provider"},
        throw: {:throw, {:provider, "SECRET-MARKER thrown by the provider"}},
        exit: {:exit, {:provider, "SECRET-MARKER exit from the provider"}}
      ] do
    @script script
    test "a provider #{kind} returns a sanitized result and logs no sensitive values" do
      user = user_fixture()
      MailerTestAdapter.script(@script)

      log =
        capture_log(fn ->
          assert {:error, {:delivery, :uncertain}} =
                   Accounts.deliver_login_instructions(
                     user,
                     &"https://tips.example/SECRET-URL/#{&1}"
                   )
        end)

      assert log =~ "uncertain"
      refute log =~ "SECRET"
      refute log =~ user.email
      assert_received {:mail_attempt, _attempt}
      refute_received {:mail_attempt, _retry}
    end
  end
end
