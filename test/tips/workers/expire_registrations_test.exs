defmodule Tips.Workers.ExpireRegistrationsTest do
  use Tips.DataCase, async: true
  use Oban.Testing, repo: Tips.Repo

  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  alias Tips.Accounts
  alias Tips.Accounts.{User, UserToken}
  alias Tips.Content.Tip
  alias Tips.Workers.ExpireRegistrations

  defp expired_registrations(count) do
    registered_at = DateTime.add(DateTime.utc_now(:second), -8, :day)

    rows =
      for _ <- 1..count do
        valid_user_attributes(%{inserted_at: registered_at, updated_at: registered_at})
      end

    {^count, users} = Repo.insert_all(User, rows, returning: [:id])
    users |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp remaining(ids), do: Repo.all(from u in User, where: u.id in ^ids, select: u.id)

  test "maintenance deletes at most the batch bound and makes progress on another run" do
    ids = expired_registrations(101)
    pending = unconfirmed_user_fixture()
    confirmed = user_fixture()
    set_registration_deadline(confirmed, -86_400)

    assert {:ok, 100} = perform_job(ExpireRegistrations, %{})
    assert remaining(ids) == [List.last(ids)]

    assert {:ok, 1} = perform_job(ExpireRegistrations, %{})
    assert remaining(ids) == []

    assert {:ok, 0} = perform_job(ExpireRegistrations, %{})
    assert %User{confirmed_at: nil} = Repo.reload!(pending)
    assert %User{confirmed_at: %DateTime{}} = Repo.reload!(confirmed)
  end

  test "a smaller bound limits the batch in id order" do
    [first, second, third] = ids = expired_registrations(3)

    assert {:ok, 2} = Accounts.expire_unconfirmed_users(2)
    assert remaining(ids) == [third]
    refute Repo.get(User, first) || Repo.get(User, second)
  end

  test "maintenance deletes the registration's tokens with it" do
    user = unconfirmed_user_fixture()
    extract_user_token(&Accounts.deliver_login_instructions(user, &1))
    Accounts.generate_user_session_token(user)
    set_registration_deadline(user, 0)

    assert {:ok, 1} = perform_job(ExpireRegistrations, %{})
    refute Repo.reload(user)
    assert Repo.all_by(UserToken, user_id: user.id) == []
  end

  test "worker repeats safely and reports invariant failures" do
    [clean] = expired_registrations(1)
    holder = unconfirmed_user_fixture()
    set_registration_deadline(holder, -1)
    %Tip{} = tip = tip_fixture(holder)

    for _attempt <- 1..2 do
      assert_raise Postgrex.Error, ~r/foreign_key_violation/, fn ->
        perform_job(ExpireRegistrations, %{})
      end

      assert %User{} = Repo.reload!(holder)
      assert %Tip{} = Repo.reload!(tip)
      assert remaining([clean]) == [clean]
    end

    Repo.delete!(tip)

    assert {:ok, 2} = perform_job(ExpireRegistrations, %{})
    assert {:ok, 0} = perform_job(ExpireRegistrations, %{})
  end

  test "an incomplete maintenance job blocks a second enqueue" do
    assert {:ok, %Oban.Job{conflict?: false, queue: "maintenance", max_attempts: 1}} =
             Oban.insert(ExpireRegistrations.new(%{}))

    assert {:ok, %Oban.Job{conflict?: true}} = Oban.insert(ExpireRegistrations.new(%{}))
    assert [%Oban.Job{}] = all_enqueued(worker: ExpireRegistrations)
  end
end
