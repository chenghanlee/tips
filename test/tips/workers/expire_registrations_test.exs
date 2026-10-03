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
    token_owner = unconfirmed_user_fixture()
    ids = [token_owner.id | expired_registrations(100)]
    extract_user_token(&Accounts.deliver_login_instructions(token_owner, &1))
    Accounts.generate_user_session_token(token_owner)

    assert Enum.sort(Enum.map(Repo.all_by(UserToken, user_id: token_owner.id), & &1.context)) ==
             ["login", "session"]

    set_registration_deadline(token_owner, 0)
    pending = unconfirmed_user_fixture()
    confirmed = user_fixture()
    set_registration_deadline(confirmed, -86_400)

    assert {:ok, 100} = perform_job(ExpireRegistrations, %{})
    assert remaining(ids) == [List.last(ids)]
    assert Repo.all_by(UserToken, user_id: token_owner.id) == []

    assert {:ok, 1} = perform_job(ExpireRegistrations, %{})
    assert remaining(ids) == []

    assert {:ok, 0} = perform_job(ExpireRegistrations, %{})
    assert %User{confirmed_at: nil} = Repo.reload!(pending)
    assert %User{confirmed_at: %DateTime{}} = Repo.reload!(confirmed)
  end

  test "worker repeats safely and reports invariant failures" do
    [clean] = expired_registrations(1)
    holder = unconfirmed_user_fixture()
    extract_user_token(&Accounts.deliver_login_instructions(holder, &1))
    Accounts.generate_user_session_token(holder)
    tokens = Repo.all_by(UserToken, user_id: holder.id) |> Enum.sort_by(& &1.id)
    assert Enum.sort(Enum.map(tokens, & &1.context)) == ["login", "session"]
    set_registration_deadline(holder, -1)
    %Tip{} = tip = tip_fixture(holder)

    assert_raise Postgrex.Error, ~r/foreign_key_violation/, fn ->
      perform_job(ExpireRegistrations, %{})
    end

    assert %User{} = Repo.reload!(holder)
    assert %Tip{} = Repo.reload!(tip)
    assert remaining([clean]) == [clean]
    assert Repo.all_by(UserToken, user_id: holder.id) |> Enum.sort_by(& &1.id) == tokens
  end

  test "an incomplete maintenance job blocks a second enqueue" do
    assert {:ok, %Oban.Job{conflict?: false, queue: "maintenance", max_attempts: 1}} =
             Oban.insert(ExpireRegistrations.new(%{}))

    assert {:ok, %Oban.Job{conflict?: true}} = Oban.insert(ExpireRegistrations.new(%{}))
    assert [%Oban.Job{}] = all_enqueued(worker: ExpireRegistrations)
  end
end
