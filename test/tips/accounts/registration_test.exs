defmodule Tips.Accounts.RegistrationTest do
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures

  alias Tips.Accounts
  alias Tips.Accounts.{User, UserToken}

  describe "suggest_handle/0" do
    test "suggestions are valid and do not create users or tokens" do
      users = Repo.aggregate(User, :count)
      tokens = Repo.aggregate(UserToken, :count)

      suggestions = for _ <- 1..50, do: Accounts.suggest_handle()

      for handle <- suggestions do
        changeset = Accounts.change_user_registration(%User{}, %{handle: handle, email: "a@b.c"})
        assert changeset.valid?, "invalid suggestion #{inspect(handle)}"
      end

      assert length(Enum.uniq(suggestions)) > 1
      assert Repo.aggregate(User, :count) == users
      assert Repo.aggregate(UserToken, :count) == tokens
    end
  end

  describe "register_user/1" do
    test "registers chosen handle and normalized email as an unconfirmed account" do
      assert {:ok, user} =
               Accounts.register_user(%{handle: "Chosen_Handle", email: " Chosen@Example.COM "})

      assert %User{handle: "Chosen_Handle", email: "chosen@example.com", confirmed_at: nil} =
               Repo.reload!(user)
    end

    test "new registrations cannot contribute" do
      {:ok, user} = Accounts.register_user(valid_user_attributes())

      assert {:error, :unconfirmed} = Accounts.check_eligibility(user, :contribute)
    end

    test "registered email offers sign in without changing the existing identity" do
      existing = unconfirmed_user_fixture(%{handle: "Original", email: "taken@example.com"})

      for email <- ["taken@example.com", " TAKEN@Example.com "] do
        assert {:error, changeset} = Accounts.register_user(%{handle: "Newcomer", email: email})
        assert %{email: ["has already been taken"]} = errors_on(changeset)
      end

      assert %User{handle: "Original", email: "taken@example.com"} = Repo.reload!(existing)
      refute Repo.get_by(User, handle: "Newcomer")
    end
  end

  describe "account settings" do
    test "settings ignores forged handle changes" do
      user = user_fixture(%{handle: "Fixed"})

      assert {:ok, changed} =
               user
               |> Accounts.change_user_email(%{email: unique_user_email(), handle: "Renamed"})
               |> Repo.update()

      assert changed.handle == "Fixed"

      assert {:ok, {changed, _}} =
               Accounts.update_user_password(user, %{
                 password: valid_user_password(),
                 handle: "Renamed"
               })

      assert changed.handle == "Fixed"
      assert %User{handle: "Fixed"} = Repo.reload!(user)
    end
  end
end
