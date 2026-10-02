defmodule Tips.Accounts.RegistrationExpiryTest do
  use Tips.DataCase, async: true

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions
  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  alias Tips.Accounts
  alias Tips.Accounts.{User, UserToken}
  alias Tips.Content.Tip

  defp magic_link(user), do: extract_user_token(&Accounts.deliver_login_instructions(user, &1))

  defp registration(seconds_left, attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)
    set_registration_deadline(user, seconds_left)
    user
  end

  defp tokens(%User{id: id}), do: Repo.all_by(UserToken, user_id: id)

  test "rejects confirmation at and after the original seven-day deadline" do
    for seconds_left <- [0, -86_400] do
      user = unconfirmed_user_fixture()
      link = magic_link(user)
      set_registration_deadline(user, seconds_left)

      refute Accounts.get_user_by_magic_link_token(link)
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(link)
      assert %User{confirmed_at: nil} = Repo.reload!(user)
      assert [%UserToken{context: "login"}] = tokens(user)
    end

    %User{id: id} = user = registration(60)
    link = magic_link(user)

    assert %User{id: ^id} = Accounts.get_user_by_magic_link_token(link)

    assert {:ok, %{user: %User{id: ^id, confirmed_at: %DateTime{}}}} =
             Accounts.login_user_by_magic_link(link)
  end

  test "resend does not extend registration" do
    expired = registration(-1)
    %User{inserted_at: registered_at} = Repo.reload!(expired)

    assert {:error, :not_found} =
             Accounts.deliver_login_instructions(expired, &"/users/log-in/#{&1}")

    assert %User{inserted_at: ^registered_at, confirmed_at: nil} = Repo.reload!(expired)
    assert tokens(expired) == []
    assert_no_email_sent()

    pending = registration(60)
    %User{inserted_at: registered_at} = Repo.reload!(pending)
    _first = magic_link(pending)

    assert {:ok, _} = Accounts.login_user_by_magic_link(magic_link(pending))
    assert %User{inserted_at: ^registered_at, confirmed_at: %DateTime{}} = Repo.reload!(pending)
  end

  test "resend for an account deleted since it was read sends nothing" do
    stale = registration(-1)
    assert {:ok, 1} = Accounts.expire_unconfirmed_users()

    assert {:error, :not_found} =
             Accounts.deliver_login_instructions(stale, &"/users/log-in/#{&1}")

    assert tokens(stale) == []
    assert_no_email_sent()
  end

  test "confirmed accounts survive expiry" do
    %User{id: id} = user = user_fixture()
    set_registration_deadline(user, -30 * 86_400)

    assert {:ok, 0} = Accounts.expire_unconfirmed_users()

    assert {:error, changeset} =
             Accounts.register_user(%{handle: "Newcomer", email: user.email})

    assert %{email: ["has already been taken"]} = errors_on(changeset)

    assert {:error, changeset} =
             Accounts.register_user(%{handle: user.handle, email: unique_user_email()})

    assert %{handle: ["has already been taken"]} = errors_on(changeset)

    assert {:ok, %{user: %User{id: ^id}}} = Accounts.login_user_by_magic_link(magic_link(user))
  end

  test "reclaims expired email and handle held by different rows" do
    email_holder = unconfirmed_user_fixture(%{email: "wanted@example.com"})
    handle_holder = unconfirmed_user_fixture(%{handle: "Wanted_Handle"})

    for user <- [email_holder, handle_holder] do
      magic_link(user)
      set_registration_deadline(user, -1)
    end

    assert {:ok, %User{id: id, handle: "wanted_handle", email: "wanted@example.com"}} =
             Accounts.register_user(%{handle: "wanted_handle", email: " WANTED@example.com "})

    refute id in [email_holder.id, handle_holder.id]

    for user <- [email_holder, handle_holder] do
      refute Repo.reload(user)
      assert tokens(user) == []
    end
  end

  test "an unexpired registration keeps its email and handle" do
    pending = registration(60)

    assert {:error, changeset} =
             Accounts.register_user(%{handle: "Newcomer", email: pending.email})

    assert %{email: ["has already been taken"]} = errors_on(changeset)

    assert {:error, changeset} =
             Accounts.register_user(%{handle: pending.handle, email: unique_user_email()})

    assert %{handle: ["has already been taken"]} = errors_on(changeset)
    assert %User{confirmed_at: nil} = Repo.reload!(pending)
  end

  test "invalid or conflicting signup rolls back reclaim" do
    expired = unconfirmed_user_fixture()
    magic_link(expired)
    set_registration_deadline(expired, -1)
    confirmed = user_fixture()

    assert {:error, changeset} = Accounts.register_user(%{handle: "x", email: expired.email})
    assert %{handle: ["has invalid format"]} = errors_on(changeset)

    assert {:error, changeset} =
             Accounts.register_user(%{handle: confirmed.handle, email: expired.email})

    assert %{handle: ["has already been taken"]} = errors_on(changeset)

    assert %User{confirmed_at: nil} = Repo.reload!(expired)
    assert [%UserToken{context: "login"}] = tokens(expired)
  end

  test "old login and session tokens cannot authenticate a replacement" do
    old = registration(60)
    old_link = magic_link(old)
    old_session = Accounts.generate_user_session_token(old)
    set_registration_deadline(old, -1)

    assert {:ok, %User{id: id} = replacement} =
             Accounts.register_user(%{handle: old.handle, email: old.email})

    refute id == old.id

    refute Accounts.get_user_by_magic_link_token(old_link)
    assert {:error, :not_found} = Accounts.login_user_by_magic_link(old_link)
    assert {:error, :not_found} = Accounts.login_user_by_magic_link(old_link, old_session)
    refute Accounts.get_user_by_session_token(old_session)
    assert {:error, :unauthenticated} = Accounts.get_scope_by_session_token(old_session)

    assert {:error, :unauthenticated} =
             Accounts.renew_user_session_token(replacement, old_session)

    assert tokens(replacement) == []
    assert %User{confirmed_at: nil} = Repo.reload!(replacement)

    assert {:ok, %{user: %User{id: ^id}}} =
             Accounts.login_user_by_magic_link(magic_link(replacement))
  end

  test "unexpected contribution FK failure is an invariant error and preserves rows and tokens" do
    holder = unconfirmed_user_fixture()
    magic_link(holder)
    set_registration_deadline(holder, -1)
    %Tip{id: tip_id} = tip_fixture(holder)
    attrs = %{handle: "Newcomer_44", email: holder.email}

    log =
      capture_log(fn ->
        assert {:error, :registration_invariant} = Accounts.register_user(attrs)
      end)

    assert log =~ "registration reclaim"
    refute log =~ holder.email
    refute log =~ attrs.handle
    refute log =~ holder.handle

    assert %User{confirmed_at: nil} = Repo.reload!(holder)
    assert [%UserToken{context: "login"}] = tokens(holder)
    assert %Tip{user_id: user_id} = Repo.get!(Tip, tip_id)
    assert user_id == holder.id
    refute Repo.get_by(User, handle: attrs.handle)
  end
end
