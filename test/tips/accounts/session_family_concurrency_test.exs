defmodule Tips.Accounts.SessionFamilyConcurrencyTest do
  # Renewal, logout and login serialize on the account row. Each operation runs on its own
  # backend; the test observes the real lock wait, then checks what the waiter decides
  # after the first transaction commits.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.LockSessions

  alias Ecto.Adapters.SQL.Sandbox
  alias Tips.Accounts
  alias Tips.Accounts.{User, UserToken}
  alias Tips.Repo

  setup do
    {user, predecessor} = committed_user_with_session()
    %{user: user, predecessor: predecessor, supervisor: start_supervised!(Task.Supervisor)}
  end

  defp committed_user_with_session do
    {user, token} =
      Sandbox.unboxed_run(Repo, fn ->
        user = user_fixture()
        {user, Accounts.generate_user_session_token(user)}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(u in User, where: u.id == ^user.id))
      end)
    end)

    {user, token}
  end

  test "renewal commits before logout and every family token is revoked", data do
    %{user: user, predecessor: predecessor} = data
    other_browser = unboxed(fn -> Accounts.generate_user_session_token(user) end)
    family = unboxed(fn -> session_row(predecessor).session_family_id end)
    renewal = open(data.supervisor)
    logout = open(data.supervisor)

    assert {:ok, successor} =
             run(renewal, fn -> Accounts.renew_user_session_token(user, predecessor) end)

    revocation = submit(logout, fn -> Accounts.revoke_user_session_family(predecessor) end)
    await_blocked(logout, renewal)
    commit(renewal)
    assert {:ok, [^family]} = await(logout, revocation)
    commit(logout)

    unboxed(fn ->
      assert family_tokens(family) == []
      refute Accounts.get_user_by_session_token(predecessor)
      refute Accounts.get_user_by_session_token(successor)
      assert {%User{}, _} = Accounts.get_user_by_session_token(other_browser)
    end)
  end

  test "logout commits before renewal and no successor is issued", data do
    %{user: user, predecessor: predecessor} = data
    other_browser = unboxed(fn -> Accounts.generate_user_session_token(user) end)
    family = unboxed(fn -> session_row(predecessor).session_family_id end)
    logout = open(data.supervisor)
    renewal = open(data.supervisor)

    assert {:ok, [^family]} =
             run(logout, fn -> Accounts.revoke_user_session_family(predecessor) end)

    late = submit(renewal, fn -> Accounts.renew_user_session_token(user, predecessor) end)
    await_blocked(renewal, logout)
    commit(logout)
    assert {:error, :unauthenticated} = await(renewal, late)
    roll_back(renewal)

    unboxed(fn ->
      assert family_tokens(family) == []
      assert [%UserToken{token: ^other_browser}] = Repo.all_by(UserToken, user_id: user.id)
      assert {%User{}, _} = Accounts.get_user_by_session_token(other_browser)
    end)
  end

  test "opposite-direction account switches lock accounts in id order", data do
    {other, other_token} = committed_user_with_session()
    [{low, _}, {high, _}] = Enum.sort_by([{data.user, nil}, {other, nil}], &elem(&1, 0).id)
    to_other = unboxed(fn -> magic_link(other) end)
    to_user = unboxed(fn -> magic_link(data.user) end)
    old_families = unboxed(fn -> family_ids([data.predecessor, other_token]) end)

    holder = open(data.supervisor)
    first = open(data.supervisor)
    second = open(data.supervisor)
    assert [_] = run(holder, fn -> lock_account(low.id, "") end)

    first_switch =
      submit(first, fn -> Accounts.login_user_by_magic_link(to_other, data.predecessor) end)

    await_blocked(first, holder)

    second_switch =
      submit(second, fn -> Accounts.login_user_by_magic_link(to_user, other_token) end)

    # The second waiter queues behind the first one's tuple lock. Both directions
    # wait on the lower id and hold nothing on the higher id.
    await_blocked(second, [holder, first])
    assert [_] = run(holder, fn -> lock_account(high.id, " NOWAIT") end)
    commit(holder)

    results =
      for _ <- 1..2 do
        receive do
          {^first_switch, result} ->
            commit(first)
            {:first, result}

          {^second_switch, result} ->
            commit(second)
            {:second, result}
        after
          3_000 -> flunk("account switch did not finish")
        end
      end

    assert %{first: {:ok, to_other_session}, second: {:ok, to_user_session}} = Map.new(results)
    other_id = other.id
    user_id = data.user.id

    unboxed(fn ->
      assert Enum.sort(to_other_session.revoked_family_ids ++ to_user_session.revoked_family_ids) ==
               Enum.sort(old_families)

      refute Accounts.get_user_by_session_token(data.predecessor)
      refute Accounts.get_user_by_session_token(other_token)

      assert {%User{id: ^other_id}, _} =
               Accounts.get_user_by_session_token(to_other_session.session_token)

      assert {%User{id: ^user_id}, _} =
               Accounts.get_user_by_session_token(to_user_session.session_token)
    end)
  end

  test "a contended single-use proof is revalidated after the lock wait", data do
    %{user: user, predecessor: predecessor} = data
    proof = unboxed(fn -> magic_link(user) end)
    first = open(data.supervisor)
    second = open(data.supervisor)

    assert {:ok, %{session_token: token}} =
             run(first, fn -> Accounts.login_user_by_magic_link(proof) end)

    replay = submit(second, fn -> Accounts.login_user_by_magic_link(proof) end)
    await_blocked(second, first)
    commit(first)
    assert {:error, :not_found} = await(second, replay)
    roll_back(second)

    unboxed(fn ->
      assert [predecessor, token] |> Enum.sort() ==
               UserToken |> Repo.all_by(user_id: user.id) |> Enum.map(& &1.token) |> Enum.sort()
    end)
  end

  test "switch revokes the known family when pruning removes the predecessor during the lock wait",
       data do
    %{user: old, predecessor: predecessor} = data
    {new, _new_session} = committed_user_with_session()

    {successor, old_family, proof} =
      unboxed(fn ->
        {:ok, successor} = Accounts.renew_user_session_token(old, predecessor)
        family = session_row(predecessor).session_family_id
        expired_at = DateTime.add(DateTime.utc_now(:second), -60, :day)

        Repo.update_all(from(t in UserToken, where: t.token == ^predecessor),
          set: [inserted_at: expired_at]
        )

        {successor, family, magic_link(new)}
      end)

    holder = open(data.supervisor)
    switcher = open(data.supervisor)
    assert [_] = run(holder, fn -> lock_account(old.id, "") end)

    # The switch has read the expired predecessor and waits on its account.
    switch = submit(switcher, fn -> Accounts.login_user_by_magic_link(proof, predecessor) end)
    await_blocked(switcher, holder)
    assert unboxed(fn -> Accounts.prune_expired_user_tokens() end) == 1
    commit(holder)
    assert {:ok, result} = await(switcher, switch)
    commit(switcher)

    unboxed(fn ->
      assert result.revoked_family_ids == [old_family]
      refute Accounts.get_user_by_session_token(successor)
      assert family_tokens(old_family) == []
    end)
  end

  defp magic_link(user), do: extract_user_token(&Accounts.deliver_login_instructions(user, &1))

  defp lock_account(id, nowait) do
    Repo.query!("SELECT id FROM users WHERE id = $1 FOR NO KEY UPDATE" <> nowait, [id]).rows
  end

  defp family_ids(tokens), do: Enum.map(tokens, &session_row(&1).session_family_id)

  defp family_tokens(family), do: Repo.all_by(UserToken, session_family_id: family)

  defp session_row(token), do: Repo.get_by!(UserToken, token: token, context: "session")
end
