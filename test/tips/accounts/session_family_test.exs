defmodule Tips.Accounts.SessionFamilyTest do
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures

  alias Tips.Accounts
  alias Tips.Accounts.{User, UserToken}

  describe "authenticated issuance" do
    test "fresh logins start independent server families with current recency" do
      user = user_fixture()
      stale = DateTime.add(DateTime.utc_now(:second), -1, :hour)

      first = Accounts.generate_user_session_token(%{user | authenticated_at: stale})
      second = Accounts.generate_user_session_token(user, nil)

      assert %UserToken{session_family_id: family, authenticated_at: first_auth} = row(first)
      assert %UserToken{session_family_id: other_family} = row(second)
      assert {:ok, _} = Ecto.UUID.cast(family)
      refute family == other_family
      assert DateTime.after?(first_auth, stale)
    end

    test "same-account reauthentication retains the family and advances recency" do
      user = user_fixture()
      predecessor = Accounts.generate_user_session_token(user)
      stale = DateTime.add(DateTime.utc_now(:second), -1, :hour)
      override_token_authenticated_at(predecessor, stale)

      token = Accounts.generate_user_session_token(user, predecessor)

      refute token == predecessor
      assert %UserToken{session_family_id: family, authenticated_at: auth} = row(token)
      assert family == row(predecessor).session_family_id
      assert DateTime.after?(auth, stale)
      assert {%User{} = session_user, _} = Accounts.get_user_by_session_token(token)
      assert Accounts.sudo_mode?(session_user)
    end

    test "reauthentication without a valid same-account predecessor starts a fresh family" do
      user = user_fixture()
      other = Accounts.generate_user_session_token(user_fixture())
      expired = Accounts.generate_user_session_token(user)
      backdate(expired, -60, :day)

      for predecessor <- [other, expired, "missing"] do
        token = Accounts.generate_user_session_token(user, predecessor)
        refute row(token).session_family_id in family_ids([other, expired])
      end
    end
  end

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
      :ok = Accounts.delete_user_session_token(deleted)
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

  defp family_ids(tokens) do
    Repo.all(from(t in UserToken, where: t.token in ^tokens, select: t.session_family_id))
  end

  defp token_count, do: Repo.aggregate(UserToken, :count)

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
