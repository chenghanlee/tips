defmodule Tips.Accounts.AuthBaselineTest do
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures

  alias Tips.Accounts
  alias Tips.Accounts.{User, UserToken}

  test "sessions are valid just before 60 days and invalid at 60 days" do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)
    user_id = user.id

    backdate_token(token, -60, :day, 60)
    assert {%User{id: ^user_id}, _inserted_at} = Accounts.get_user_by_session_token(token)

    backdate_token(token, -60, :day)
    assert is_nil(Accounts.get_user_by_session_token(token))
  end

  test "magic links are valid just before 15 minutes and invalid at 15 minutes" do
    user = user_fixture()
    token = extract_user_token(&Accounts.deliver_login_instructions(user, &1))
    user_id = user.id
    stored_token = email_token_hash(token)

    backdate_token(stored_token, -15, :minute, 10)
    assert %User{id: ^user_id} = Accounts.get_user_by_magic_link_token(token)

    backdate_token(stored_token, -15, :minute)
    assert is_nil(Accounts.get_user_by_magic_link_token(token))
    assert {:error, :not_found} = Accounts.login_user_by_magic_link(token)
  end

  test "email-change links update the email just before 7 days" do
    user = user_fixture()
    new_email = unique_user_email()
    token = change_email_token(user, new_email)

    backdate_token(email_token_hash(token), -7, :day, 60)

    assert {:ok, %User{email: ^new_email}} = Accounts.update_user_email(user, token)
    assert Accounts.get_user!(user.id).email == new_email
  end

  test "email-change links leave the email unchanged at 7 days" do
    user = user_fixture()
    token = change_email_token(user, unique_user_email())

    backdate_token(email_token_hash(token), -7, :day)

    assert {:error, :transaction_aborted} = Accounts.update_user_email(user, token)
    assert Accounts.get_user!(user.id).email == user.email
  end

  test "session renewal preserves authenticated_at; magic-link reauthentication advances it" do
    user = user_fixture()
    assert user.confirmed_at
    user_id = user.id
    previous_auth = DateTime.add(DateTime.utc_now(:second), -1, :hour)
    session_a = Accounts.generate_user_session_token(user)
    override_token_authenticated_at(session_a, previous_auth)

    assert {%User{id: ^user_id, authenticated_at: ^previous_auth} = session_user, _inserted_at} =
             Accounts.get_user_by_session_token(session_a)

    assert {:ok, session_b} = Accounts.renew_user_session_token(session_user, session_a)
    refute session_b == session_a
    assert %UserToken{authenticated_at: ^previous_auth} = session_row(session_b)
    assert {renewed_user, _inserted_at} = Accounts.get_user_by_session_token(session_b)
    refute Accounts.sudo_mode?(renewed_user)

    magic_link = extract_user_token(&Accounts.deliver_login_instructions(session_user, &1))

    assert {:ok, %{user: %User{id: ^user_id}, session_token: session_c, revoked_family_ids: []}} =
             Accounts.login_user_by_magic_link(magic_link, session_b)

    assert %UserToken{authenticated_at: current_auth} = session_row(session_c)
    assert DateTime.after?(current_auth, previous_auth)
    assert {fresh_user, _inserted_at} = Accounts.get_user_by_session_token(session_c)
    assert fresh_user.authenticated_at == current_auth
    assert Accounts.sudo_mode?(fresh_user)
    assert {:error, :not_found} = Accounts.login_user_by_magic_link(magic_link)

    family = session_row(session_a).session_family_id
    assert Enum.all?([session_b, session_c], &(session_row(&1).session_family_id == family))

    # Renewal and reauthentication keep predecessors until expiry or family revocation.
    assert {%User{authenticated_at: ^previous_auth}, _} =
             Accounts.get_user_by_session_token(session_a)

    assert {%User{authenticated_at: ^previous_auth}, _} =
             Accounts.get_user_by_session_token(session_b)
  end

  defp session_row(token), do: Repo.get_by!(UserToken, token: token, context: "session")

  defp change_email_token(user, new_email) do
    extract_user_token(fn url ->
      Accounts.deliver_user_update_email_instructions(%{user | email: new_email}, user.email, url)
    end)
  end

  defp email_token_hash(token) do
    token |> Base.url_decode64!(padding: false) |> then(&:crypto.hash(:sha256, &1))
  end

  # Moves `inserted_at` to `amount` `unit`s ago, then `extra_seconds` closer to now.
  defp backdate_token(token, amount, unit, extra_seconds \\ 0) do
    inserted_at =
      DateTime.utc_now(:second) |> DateTime.add(amount, unit) |> DateTime.add(extra_seconds)

    assert {1, nil} =
             Repo.update_all(from(t in UserToken, where: t.token == ^token),
               set: [inserted_at: inserted_at]
             )
  end
end
