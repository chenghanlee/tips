defmodule Tips.Accounts.AuthBaselineTest do
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures

  alias Tips.Accounts
  alias Tips.Accounts.{User, UserToken}

  test "generator 14-day sessions are valid at 13 days and invalid at 15 days" do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)
    user_id = user.id

    backdate_token(token, -13, :day)
    assert {%User{id: ^user_id}, _inserted_at} = Accounts.get_user_by_session_token(token)

    backdate_token(token, -15, :day)
    assert is_nil(Accounts.get_user_by_session_token(token))
  end

  test "generator 15-minute magic links are valid at 14 minutes and invalid at 16 minutes" do
    user = user_fixture()
    token = extract_user_token(&Accounts.deliver_login_instructions(user, &1))
    user_id = user.id
    stored_token = email_token_hash(token)

    backdate_token(stored_token, -14, :minute)
    assert %User{id: ^user_id} = Accounts.get_user_by_magic_link_token(token)

    backdate_token(stored_token, -16, :minute)
    assert is_nil(Accounts.get_user_by_magic_link_token(token))
    assert {:error, :not_found} = Accounts.login_user_by_magic_link(token)
  end

  test "generator 7-day email-change links update the email at 6 days" do
    user = user_fixture()
    new_email = unique_user_email()
    token = change_email_token(user, new_email)

    backdate_token(email_token_hash(token), -6, :day)

    assert {:ok, %User{email: ^new_email}} = Accounts.update_user_email(user, token)
    assert Accounts.get_user!(user.id).email == new_email
  end

  test "generator 7-day email-change links leave the email unchanged at 8 days" do
    user = user_fixture()
    token = change_email_token(user, unique_user_email())

    backdate_token(email_token_hash(token), -8, :day)

    assert {:error, :transaction_aborted} = Accounts.update_user_email(user, token)
    assert Accounts.get_user!(user.id).email == user.email
  end

  test "generator session reissue preserves authenticated_at; magic-link reauthentication advances it" do
    user = user_fixture()
    assert user.confirmed_at
    user_id = user.id
    previous_auth = DateTime.add(DateTime.utc_now(:second), -1, :hour)
    session_a = Accounts.generate_user_session_token(%{user | authenticated_at: previous_auth})

    assert %UserToken{authenticated_at: ^previous_auth} = session_row(session_a)

    assert {%User{id: ^user_id, authenticated_at: ^previous_auth} = session_user, _inserted_at} =
             Accounts.get_user_by_session_token(session_a)

    session_b = Accounts.generate_user_session_token(session_user)
    refute session_b == session_a
    assert %UserToken{authenticated_at: ^previous_auth} = session_row(session_b)
    assert {renewed_user, _inserted_at} = Accounts.get_user_by_session_token(session_b)
    refute Accounts.sudo_mode?(renewed_user)

    magic_link = extract_user_token(&Accounts.deliver_login_instructions(session_user, &1))

    assert {:ok, {%User{id: ^user_id, authenticated_at: nil} = reauthenticated_user, []}} =
             Accounts.login_user_by_magic_link(magic_link)

    session_c = Accounts.generate_user_session_token(reauthenticated_user)
    assert %UserToken{authenticated_at: current_auth} = session_row(session_c)
    assert DateTime.after?(current_auth, previous_auth)
    assert {fresh_user, _inserted_at} = Accounts.get_user_by_session_token(session_c)
    assert fresh_user.authenticated_at == current_auth
    assert Accounts.sudo_mode?(fresh_user)
    assert {:error, :not_found} = Accounts.login_user_by_magic_link(magic_link)

    # The generator has no family revocation: these predecessor rows still authenticate.
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

  defp backdate_token(token, amount, unit) do
    inserted_at = DateTime.add(DateTime.utc_now(:second), amount, unit)

    assert {1, nil} =
             Repo.update_all(from(t in UserToken, where: t.token == ^token),
               set: [inserted_at: inserted_at]
             )
  end
end
