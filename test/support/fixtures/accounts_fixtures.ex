defmodule Tips.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Tips.Accounts` context.
  """

  import Ecto.Query

  alias Tips.Accounts
  alias Tips.Accounts.Scope

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      handle: "user#{System.unique_integer([:positive])}",
      email: unique_user_email()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_login_instructions(user, url)
      end)

    # Confirming logs in; drop that session so the fixture user starts signed out.
    {:ok, %{user: user}} = Accounts.login_user_by_magic_link(token)
    {:ok, [_family]} = Accounts.revoke_user_session_families(user)

    user
  end

  @doc """
  Moves the user's seven-day registration deadline to `seconds_left` from now
  on the database clock, by rewriting `inserted_at`. Zero or less is expired.
  """
  def set_registration_deadline(%Accounts.User{id: id}, seconds_left) do
    Tips.Repo.query!(
      "UPDATE users SET inserted_at = clock_timestamp() - interval '7 days' + make_interval(secs => $1) WHERE id = $2",
      [seconds_left * 1.0, id]
    )

    :ok
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Tips.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    Tips.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Tips.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
