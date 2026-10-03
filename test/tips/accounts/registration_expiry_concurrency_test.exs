defmodule Tips.Accounts.RegistrationExpiryConcurrencyTest do
  # Confirmation, maintenance cleanup and signup reclaim serialize on the account row. Each
  # runs on its own backend; the test observes the real lock wait, lets the registration
  # deadline pass on the database clock where the scenario needs it, then checks what the
  # waiter decides once the first transaction commits.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Swoosh.TestAssertions
  import Tips.AccountsFixtures
  import Tips.DataCase, only: [errors_on: 1]
  import Tips.LockSessions

  alias Tips.Accounts
  alias Tips.Accounts.{User, UserToken}
  alias Tips.Repo

  # Long enough to reach the lock, short enough to wait out within the repo's query timeout.
  @seconds_left 1.0

  setup do
    prefix = "exp#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from(u in User, where: like(u.email, ^"#{prefix}%"))) end)
    end)

    %{prefix: prefix, supervisor: start_supervised!(Task.Supervisor)}
  end

  # A committed unconfirmed registration and its login link.
  defp committed_registration(prefix, name, seconds_left) do
    unboxed(fn ->
      user = unconfirmed_user_fixture(attrs(prefix, name))
      link = extract_user_token(&Accounts.deliver_login_instructions(user, &1))
      set_registration_deadline(user, seconds_left)
      {user, link}
    end)
  end

  defp attrs(prefix, name),
    do: %{handle: "#{prefix}_#{name}", email: "#{prefix}.#{name}@example.com"}

  # Set once the sessions are open, so the whole margin is left for the step under test.
  defp approach_deadline(user) do
    unboxed(fn -> set_registration_deadline(user, @seconds_left) end)
  end

  # Waits on the database clock, the one the application's deadline check reads.
  defp await_deadline(%User{id: id}) do
    unboxed(fn ->
      %{rows: [[seconds]]} =
        Repo.query!(
          "SELECT extract(epoch FROM inserted_at + interval '7 days' - clock_timestamp())::float8 FROM users WHERE id = $1",
          [id]
        )

      if seconds > 0, do: Process.sleep(ceil(seconds * 1000) + 5)
    end)
  end

  defp lock_account(id, nowait) do
    Repo.query!("SELECT id FROM users WHERE id = $1 FOR UPDATE" <> nowait, [id]).rows
  end

  defp tokens(%User{id: id}), do: Repo.all_by(UserToken, user_id: id)

  test "confirmation wins before cleanup and reclaim", %{prefix: prefix, supervisor: supervisor} do
    {user, link} = committed_registration(prefix, "a", 60)
    user_id = user.id
    confirmation = open(supervisor)
    cleanup = open(supervisor)
    approach_deadline(user)

    assert {:ok, %{session_token: session}} =
             run(confirmation, fn -> Accounts.login_user_by_magic_link(link) end)

    # The committed row is still unconfirmed and now past its deadline: cleanup selects it
    # and waits for the confirmation that holds its lock.
    await_deadline(user)
    expiry = submit(cleanup, fn -> Accounts.expire_unconfirmed_users() end)
    await_blocked(cleanup, confirmation)
    commit(confirmation)
    assert {:ok, 0} = await(cleanup, expiry)
    commit(cleanup)

    unboxed(fn ->
      assert %User{confirmed_at: %DateTime{}} = Repo.get!(User, user_id)
      assert {%User{id: ^user_id}, _} = Accounts.get_user_by_session_token(session)
    end)
  end

  test "confirmation rechecks wall time after a lock wait crosses the deadline",
       %{prefix: prefix, supervisor: supervisor} do
    {user, link} = committed_registration(prefix, "a", 60)
    holder = open(supervisor)
    confirmation = open(supervisor)
    approach_deadline(user)
    assert [_] = run(holder, fn -> lock_account(user.id, "") end)

    # The proof is valid when read; the wait for the account lock outlasts the deadline.
    login = submit(confirmation, fn -> Accounts.login_user_by_magic_link(link) end)
    await_blocked(confirmation, holder)
    await_deadline(user)
    commit(holder)
    assert {:error, :not_found} = await(confirmation, login)
    roll_back(confirmation)

    unboxed(fn ->
      assert %User{confirmed_at: nil} = Repo.get!(User, user.id)
      assert [%UserToken{context: "login"}] = tokens(user)
    end)
  end

  # The proof is read as valid, then the confirmation waits on the account lock while the
  # deadline passes and the lock holder deletes the registration.
  for {winner, delete} <- [
        reclaim: quote(do: Accounts.register_user(attrs(var!(prefix), "a")))
      ] do
    test "#{winner} deletes a registration whose proof was valid before the lock wait",
         %{prefix: prefix, supervisor: supervisor} do
      {user, link} = committed_registration(prefix, "a", 60)
      winner = open(supervisor)
      confirmation = open(supervisor)
      approach_deadline(user)
      assert [_] = run(winner, fn -> lock_account(user.id, "") end)

      login = submit(confirmation, fn -> Accounts.login_user_by_magic_link(link) end)
      await_blocked(confirmation, winner)
      await_deadline(user)
      assert {:ok, deleted} = run(winner, fn -> unquote(delete) end)
      commit(winner)
      assert {:error, :not_found} = await(confirmation, login)
      roll_back(confirmation)

      unboxed(fn ->
        refute Repo.get(User, user.id)
        assert tokens(user) == []

        case deleted do
          1 -> refute Accounts.get_user_by_email(user.email)
          %User{id: id} -> assert %User{id: ^id, confirmed_at: nil} = Repo.get!(User, id)
        end
      end)
    end
  end

  test "resend waiting on cleanup finds the account gone and sends nothing",
       %{prefix: prefix, supervisor: supervisor} do
    {user, _link} = committed_registration(prefix, "a", -1)
    cleanup = open(supervisor)
    resend = open(supervisor)

    assert {:ok, 1} = run(cleanup, fn -> Accounts.expire_unconfirmed_users() end)

    delivery =
      submit(resend, fn ->
        result = Accounts.deliver_login_instructions(user, &"/users/log-in/#{&1}")
        assert_no_email_sent()
        result
      end)

    await_blocked(resend, cleanup)
    commit(cleanup)
    assert {:error, :not_found} = await(resend, delivery)
    roll_back(resend)

    unboxed(fn ->
      refute Repo.get(User, user.id)
      assert tokens(user) == []
    end)
  end

  test "reclaim rechecks current confirmation after waiting",
       %{prefix: prefix, supervisor: supervisor} do
    {user, link} = committed_registration(prefix, "a", 60)
    user_id = user.id
    confirmation = open(supervisor)
    reclaim = open(supervisor)
    approach_deadline(user)

    assert {:ok, _} = run(confirmation, fn -> Accounts.login_user_by_magic_link(link) end)

    await_deadline(user)
    signup = submit(reclaim, fn -> Accounts.register_user(attrs(prefix, "a")) end)
    await_blocked(reclaim, confirmation)
    commit(confirmation)
    assert {:error, changeset} = await(reclaim, signup)
    assert %{email: ["has already been taken"]} = errors_on(changeset)
    roll_back(reclaim)

    unboxed(fn ->
      assert [%User{id: ^user_id, confirmed_at: %DateTime{}}] =
               Repo.all(from(u in User, where: like(u.email, ^"#{prefix}%")))
    end)
  end

  test "opposite identity conflicts lock accounts in id order",
       %{prefix: prefix, supervisor: supervisor} do
    {low, _} = committed_registration(prefix, "a", -1)
    {high, _} = committed_registration(prefix, "b", -1)
    assert low.id < high.id

    holder = open(supervisor)
    first = open(supervisor)
    second = open(supervisor)
    assert [_] = run(holder, fn -> lock_account(low.id, "") end)

    first_signup =
      submit(first, fn -> Accounts.register_user(%{handle: high.handle, email: low.email}) end)

    await_blocked(first, holder)

    second_signup =
      submit(second, fn -> Accounts.register_user(%{handle: low.handle, email: high.email}) end)

    # The second waiter queues behind the first one's tuple lock. Both directions wait on
    # the lower id and hold nothing on the higher id.
    await_blocked(second, [holder, first])
    assert [_] = run(holder, fn -> lock_account(high.id, " NOWAIT") end)
    commit(holder)

    results =
      for _ <- 1..2 do
        receive do
          {^first_signup, result} ->
            commit(first)
            {:first, result}

          {^second_signup, result} ->
            commit(second)
            {:second, result}
        after
          3_000 -> flunk("signup did not finish")
        end
      end

    assert %{first: {:ok, %User{} = first_user}, second: {:ok, %User{} = second_user}} =
             Map.new(results)

    unboxed(fn ->
      refute Repo.get(User, low.id) || Repo.get(User, high.id)

      assert Enum.sort([first_user.id, second_user.id]) ==
               Repo.all(
                 from(u in User,
                   where: like(u.email, ^"#{prefix}%"),
                   order_by: u.id,
                   select: u.id
                 )
               )
    end)
  end
end
