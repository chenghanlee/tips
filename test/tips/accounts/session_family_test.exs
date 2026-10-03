defmodule Tips.Accounts.SessionFamilyTest do
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures

  alias Tips.Accounts
  alias Tips.Accounts.{User, UserToken}

  describe "renew_user_session_token/2" do
    test "copies the family and database recency; renewal cannot restore sudo" do
      user = user_fixture()
      predecessor = Accounts.generate_user_session_token(user)
      stale = DateTime.add(DateTime.utc_now(:second), -1, :hour)
      override_token_authenticated_at(predecessor, stale)
      fresh_claim = %{user | authenticated_at: DateTime.utc_now(:second)}

      assert {:ok, token} = Accounts.renew_user_session_token(fresh_claim, predecessor)

      refute token == predecessor
      assert byte_size(token) == 32
      assert %UserToken{authenticated_at: ^stale, session_family_id: family} = row(token)
      assert family == row(predecessor).session_family_id
      assert {session_user, _} = Accounts.get_user_by_session_token(token)
      refute Accounts.sudo_mode?(session_user)
      assert Accounts.get_user_by_session_token(predecessor)
    end

    test "a full ban does not reject renewal" do
      user = user_fixture()
      predecessor = Accounts.generate_user_session_token(user)
      banned_at = DateTime.utc_now(:second)

      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [ban: :full, banned_at: banned_at]
      )

      assert {:ok, _token} = Accounts.renew_user_session_token(user, predecessor)
    end

    test "invalid predecessors are rejected without creating a successor" do
      user = user_fixture()
      other_user = user_fixture()
      wrong_account = Accounts.generate_user_session_token(other_user)
      expired = Accounts.generate_user_session_token(user)
      backdate(expired, -60, :day)
      deleted = Accounts.generate_user_session_token(user)
      {:ok, [_family]} = Accounts.revoke_user_session_family(deleted)
      login = email_token_row(user, "login")
      change = email_token_row(user, "change:#{user.email}")

      for predecessor <- [wrong_account, expired, deleted, "missing", login.token, change.token] do
        count = token_count()
        assert {:error, :unauthenticated} = Accounts.renew_user_session_token(user, predecessor)
        assert token_count() == count
      end
    end

    test "a deleted current account cannot renew" do
      user = user_fixture()
      predecessor = Accounts.generate_user_session_token(user)
      deleted_at = DateTime.utc_now(:second)

      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [deleted_at: deleted_at, handle: nil, email: nil]
      )

      count = token_count()

      assert {:error, :unauthenticated} = Accounts.renew_user_session_token(user, predecessor)
      assert token_count() == count
    end
  end

  describe "revoke_user_session_family/1" do
    test "family revocation preserves another browser and non-session tokens" do
      user = user_fixture()
      initial = Accounts.generate_user_session_token(user)
      {:ok, successor} = Accounts.renew_user_session_token(user, initial)
      other_browser = Accounts.generate_user_session_token(user)
      other_account = Accounts.generate_user_session_token(user_fixture())
      login = email_token_row(user, "login")
      change = email_token_row(user, "change:#{user.email}")
      family = row(initial).session_family_id

      assert {:ok, [^family]} = Accounts.revoke_user_session_family(successor)

      refute Accounts.get_user_by_session_token(initial)
      refute Accounts.get_user_by_session_token(successor)
      assert Repo.all_by(UserToken, session_family_id: family) == []
      assert {%User{}, _} = Accounts.get_user_by_session_token(other_browser)
      assert {%User{}, _} = Accounts.get_user_by_session_token(other_account)
      assert Repo.get(UserToken, login.id)
      assert Repo.get(UserToken, change.id)
    end

    test "absent, already revoked and non-session tokens revoke nothing" do
      user = user_fixture()
      revoked = Accounts.generate_user_session_token(user)
      assert {:ok, [_family]} = Accounts.revoke_user_session_family(revoked)
      login = email_token_row(user, "login")
      count = token_count()

      for token <- [revoked, "missing", login.token] do
        assert {:ok, []} = Accounts.revoke_user_session_family(token)
        assert token_count() == count
      end
    end

    test "an expired row identifies its family for logout but never authenticates" do
      user = user_fixture()
      expired = Accounts.generate_user_session_token(user)
      {:ok, successor} = Accounts.renew_user_session_token(user, expired)
      backdate(expired, -60, :day)
      family = row(expired).session_family_id

      refute Accounts.get_user_by_session_token(expired)
      assert {:error, :unauthenticated} = Accounts.renew_user_session_token(user, expired)
      assert {:ok, [^family]} = Accounts.revoke_user_session_family(expired)
      refute Accounts.get_user_by_session_token(successor)
    end

    test "a deleted account's family can still be revoked" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      family = row(token).session_family_id
      delete_account(user)

      assert {:ok, [^family]} = Accounts.revoke_user_session_family(token)
      assert Repo.all_by(UserToken, session_family_id: family) == []
    end
  end

  describe "login_user_by_magic_link/2" do
    test "valid same-account reauthentication retains the family and advances recency" do
      user = user_fixture()
      predecessor = Accounts.generate_user_session_token(user)
      stale = DateTime.add(DateTime.utc_now(:second), -1, :hour)
      override_token_authenticated_at(predecessor, stale)
      family = row(predecessor).session_family_id

      assert {:ok, %{user: %User{} = returned, session_token: token, revoked_family_ids: []}} =
               Accounts.login_user_by_magic_link(magic_link(user), predecessor)

      assert returned.id == user.id
      refute token == predecessor
      assert %UserToken{session_family_id: ^family, authenticated_at: auth} = row(token)
      assert DateTime.after?(auth, stale)
      assert {session_user, _} = Accounts.get_user_by_session_token(token)
      assert Accounts.sudo_mode?(session_user)

      assert {%User{authenticated_at: ^stale}, _} =
               Accounts.get_user_by_session_token(predecessor)
    end

    test "missing, revoked and expired predecessors start a fresh family and stay coherent" do
      user = user_fixture()
      revoked = Accounts.generate_user_session_token(user)
      {:ok, [revoked_family]} = Accounts.revoke_user_session_family(revoked)
      expired = Accounts.generate_user_session_token(user)
      backdate(expired, -60, :day)
      expired_family = row(expired).session_family_id

      for predecessor <- [nil, "missing", revoked, expired] do
        assert {:ok, %{session_token: token, revoked_family_ids: []}} =
                 Accounts.login_user_by_magic_link(magic_link(user), predecessor)

        refute row(token).session_family_id in [revoked_family, expired_family]
        assert {%User{}, _} = Accounts.get_user_by_session_token(token)
      end

      refute Accounts.get_user_by_session_token(expired)
    end

    test "a valid switch revokes the other account's browser family only" do
      old = user_fixture()
      new = user_fixture()
      initial = Accounts.generate_user_session_token(old)
      {:ok, sibling} = Accounts.renew_user_session_token(old, initial)
      other_browser = Accounts.generate_user_session_token(old)
      new_elsewhere = Accounts.generate_user_session_token(new)
      old_family = row(initial).session_family_id
      new_id = new.id

      assert {:ok, %{user: %User{id: ^new_id}, session_token: token, revoked_family_ids: ids}} =
               Accounts.login_user_by_magic_link(magic_link(new), sibling)

      assert ids == [old_family]
      refute Accounts.get_user_by_session_token(initial)
      refute Accounts.get_user_by_session_token(sibling)
      assert {%User{id: ^new_id}, _} = Accounts.get_user_by_session_token(token)
      refute row(token).session_family_id == old_family
      assert {%User{}, _} = Accounts.get_user_by_session_token(other_browser)
      assert {%User{}, _} = Accounts.get_user_by_session_token(new_elsewhere)
    end

    test "a rejected proof changes no session family" do
      old = user_fixture()
      new = user_fixture()
      predecessor = Accounts.generate_user_session_token(old)
      expired = magic_link(new)
      backdate(hashed(expired), -15, :minute)
      replayed = magic_link(new)
      assert {:ok, _} = Accounts.login_user_by_magic_link(replayed)
      deleted = user_fixture()
      deleted_proof = magic_link(deleted)
      delete_account(deleted)
      tokens = all_tokens()

      for proof <-
            ["%", Base.url_encode64("unknown", padding: false), expired, replayed] ++
              [deleted_proof] do
        assert {:error, :not_found} = Accounts.login_user_by_magic_link(proof, predecessor)
        assert all_tokens() == tokens
      end

      assert {%User{}, _} = Accounts.get_user_by_session_token(predecessor)
    end

    test "a switch away from a deleted account still revokes its family" do
      old = user_fixture()
      predecessor = Accounts.generate_user_session_token(old)
      family = row(predecessor).session_family_id
      delete_account(old)

      assert {:ok, %{revoked_family_ids: [^family]}} =
               Accounts.login_user_by_magic_link(magic_link(user_fixture()), predecessor)

      assert Repo.all_by(UserToken, session_family_id: family) == []
    end

    test "first confirmation revokes every earlier session family of the account" do
      user = unconfirmed_user_fixture()
      earlier = Accounts.generate_user_session_token(user)
      family = row(earlier).session_family_id

      assert {:ok, %{user: %User{confirmed_at: %DateTime{}}, session_token: token} = result} =
               Accounts.login_user_by_magic_link(magic_link(user), earlier)

      assert result.revoked_family_ids == [family]
      assert [%UserToken{token: ^token}] = Repo.all_by(UserToken, user_id: user.id)
      refute row(token).session_family_id == family
    end
  end

  describe "prune_expired_user_tokens/1" do
    test "deletes expired rows by context validity and keeps valid successors" do
      user = user_fixture()
      initial = Accounts.generate_user_session_token(user)
      backdate(initial, -8, :day)
      assert {:ok, successor} = Accounts.renew_user_session_token(user, initial)
      family = row(initial).session_family_id
      backdate(initial, -60, :day)
      young_session = Accounts.generate_user_session_token(user)
      backdate(young_session, -60, :day, 60)

      expired_login = email_token_row(user, "login", -15, :minute)
      young_login = email_token_row(user, "login", -15, :minute, 60)
      expired_change = email_token_row(user, "change:a@example.com", -7, :day)
      young_change = email_token_row(user, "change:b@example.com", -7, :day, 60)
      unknown = Repo.insert!(%UserToken{token: "unknown", context: "other", user_id: user.id})
      backdate(unknown.token, -365, :day)

      assert Accounts.prune_expired_user_tokens() == 3

      refute Repo.get_by(UserToken, token: initial)
      refute Repo.get(UserToken, expired_login.id)
      refute Repo.get(UserToken, expired_change.id)
      assert {%User{}, _} = Accounts.get_user_by_session_token(successor)
      assert row(successor).session_family_id == family
      assert Repo.get_by(UserToken, token: young_session)
      assert Repo.get(UserToken, young_login.id)
      assert Repo.get(UserToken, young_change.id)
      assert Repo.get(UserToken, unknown.id)
    end

    test "deletes at most the batch limit, oldest first" do
      user = user_fixture()

      [oldest, middle, newest] =
        for days <- [-90, -80, -70] do
          token = Accounts.generate_user_session_token(user)
          backdate(token, days, :day)
          token
        end

      assert Accounts.prune_expired_user_tokens(2) == 2
      refute Repo.get_by(UserToken, token: oldest)
      refute Repo.get_by(UserToken, token: middle)
      assert Repo.get_by(UserToken, token: newest)
      assert Accounts.prune_expired_user_tokens(2) == 1
      assert Accounts.prune_expired_user_tokens(2) == 0
    end
  end

  defp row(token), do: Repo.get_by!(UserToken, token: token, context: "session")

  defp token_count, do: Repo.aggregate(UserToken, :count)

  defp all_tokens, do: UserToken |> Repo.all() |> Enum.sort_by(& &1.id)

  defp magic_link(user), do: extract_user_token(&Accounts.deliver_login_instructions(user, &1))

  defp hashed(magic_link),
    do: :crypto.hash(:sha256, Base.url_decode64!(magic_link, padding: false))

  defp delete_account(user) do
    Repo.update_all(from(u in User, where: u.id == ^user.id),
      set: [deleted_at: DateTime.utc_now(:second), handle: nil, email: nil]
    )
  end

  defp email_token_row(user, context, amount \\ 0, unit \\ :second, extra_seconds \\ 0) do
    {_encoded, token} = UserToken.build_email_token(user, context)
    token = Repo.insert!(token)
    backdate(token.token, amount, unit, extra_seconds)
    token
  end

  # Moves `inserted_at` to `amount` `unit`s ago, then `extra_seconds` closer to now.
  defp backdate(token, amount, unit, extra_seconds \\ 0) do
    inserted_at =
      DateTime.utc_now(:second) |> DateTime.add(amount, unit) |> DateTime.add(extra_seconds)

    assert {1, nil} =
             Repo.update_all(from(t in UserToken, where: t.token == ^token),
               set: [inserted_at: inserted_at]
             )
  end
end
