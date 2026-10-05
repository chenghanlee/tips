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

  # When the attempt's kill timer fires before the caller's wait ends, the caller sees the
  # killed task and reports :uncertain. Either is a sanitized failure; timing tests prove
  # expiry, termination and one attempt separately.
  @deadline_categories [:timeout, :uncertain]

  defp budget_ms,
    do: Application.fetch_env!(:tips, Tips.Accounts.UserNotifier)[:delivery_budget_ms]

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp url(token), do: "https://tips.example/users/log-in/#{token}"

  defp token_contexts(user) do
    Repo.all(from t in UserToken, where: t.user_id == ^user.id, select: t.context)
  end

  defp assert_identity_unchanged(user) do
    assert %User{email: email, handle: handle, confirmed_at: confirmed_at} = Repo.reload!(user)
    assert {email, handle, confirmed_at} == {user.email, user.handle, user.confirmed_at}
  end

  test "delivery failures preserve committed identity and token" do
    user = user_fixture()
    MailerTestAdapter.script(:reject)

    assert {:error, {:delivery, :uncertain}} = Accounts.deliver_login_instructions(user, &url/1)

    assert {:error, {:delivery, :uncertain}} =
             Accounts.deliver_user_update_email_instructions(
               %{user | email: unique_user_email()},
               user.email,
               &url/1
             )

    assert Enum.sort(token_contexts(user)) == Enum.sort(["login", "change:#{user.email}"])
    assert_identity_unchanged(user)

    # One attempt per request; nothing retries.
    assert_received {:mail_attempt, _first}
    assert_received {:mail_attempt, _second}
    refute_received {:mail_attempt, _third}
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

    assert {:error, {:delivery, category}} = Task.await(caller, budget_ms() + @slack_ms)
    assert category in @deadline_categories
    assert (now_ms() - started) in budget_ms()..(budget_ms() + @slack_ms)
    refute Process.alive?(attempt)
    assert token_contexts(user) == ["login"]
    assert_identity_unchanged(user)
    refute_received {:mail_attempt, _retry}
  end

  test "the attempt's kill timer ends it at the deadline without the caller" do
    user = user_fixture()
    MailerTestAdapter.script(:block)
    started = now_ms()

    caller = Task.async(fn -> Accounts.deliver_login_instructions(user, &url/1) end)

    assert_receive {:mail_attempt, attempt}, budget_ms()
    ref = Process.monitor(attempt)
    # Hold the caller so only the kill timer can end the attempt.
    :erlang.suspend_process(caller.pid)
    assert_receive {:DOWN, ^ref, :process, ^attempt, _reason}, budget_ms() + @slack_ms
    assert (now_ms() - started) in budget_ms()..(budget_ms() + @slack_ms)
    :erlang.resume_process(caller.pid)

    assert {:error, {:delivery, category}} = Task.await(caller)
    assert category in @deadline_categories
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
