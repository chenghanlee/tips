defmodule Tips.Accounts.IdentitySchemaTest do
  use Tips.DataCase, async: true

  alias Tips.Accounts
  alias Tips.Accounts.{User, UserToken}

  import Tips.AccountsFixtures

  describe "registration boundary" do
    for handle <- [
          nil,
          "ab",
          "_abc",
          "has.dot",
          "valid\n",
          String.duplicate("a", 31)
        ] do
      test "registration rejects invalid handle #{inspect(handle)}" do
        changeset =
          User.registration_changeset(%User{}, %{
            email: unique_user_email(),
            handle: unquote(handle)
          })

        assert %{handle: [_ | _]} = errors_on(changeset)
      end
    end

    for handle <- ~w(admin) do
      test "registration rejects reserved handle #{handle} case-insensitively" do
        for variant <- [unquote(handle), String.upcase(unquote(handle))] do
          changeset =
            User.registration_changeset(%User{}, %{email: unique_user_email(), handle: variant})

          assert %{handle: ["is reserved"]} = errors_on(changeset)
        end
      end
    end

    test "registers with preserved handle case, normalized email and user defaults" do
      assert {:ok, user} =
               Accounts.register_user(%{
                 handle: "Mixed_Handle-1",
                 email: "  MiXeD@Example.com \n",
                 role: :moderator,
                 ban: :full
               })

      assert %{handle: "Mixed_Handle-1", email: "mixed@example.com", role: :user, ban: nil} =
               Repo.reload!(user)

      assert Accounts.get_user_by_email(" MIXED@EXAMPLE.COM ").id == user.id
    end

    test "database email collision maps to a changeset error even when the precheck misses" do
      insert_user(%{email: "MIXED@example.com"})

      assert {:error, changeset} =
               Accounts.register_user(%{handle: "AnotherHandle", email: "mixed@example.com"})

      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end

    test "email changes normalize without changing the handle" do
      user = insert_user()

      assert {:ok, changed} =
               user
               |> Accounts.change_user_email(%{email: " NEW@Example.com ", handle: "Replacement"})
               |> Repo.update()

      assert changed.email == "new@example.com"
      assert changed.handle == user.handle
    end

    test "clearing an existing email returns validation errors" do
      user = insert_user()

      for email <- [nil, "", "   "] do
        changeset = Accounts.change_user_email(user, %{email: email})
        assert "can't be blank" in errors_on(changeset).email
      end
    end

    for space <- ["\u00A0"] do
      test "registration rejects embedded Unicode whitespace #{inspect(space)}" do
        assert {:error, changeset} =
                 Accounts.register_user(%{
                   handle: "ValidHandle",
                   email: "a#{unquote(space)}b@example.com"
                 })

        assert "must have the @ sign and no spaces" in errors_on(changeset).email
      end
    end

    test "registration accepts a 30-character handle and a Unicode email" do
      handle = String.duplicate("a", 30)

      assert {:ok, %{handle: ^handle, email: "ünï@例え.jp"}} =
               Accounts.register_user(%{handle: handle, email: "ünï@例え.jp"})
    end
  end

  describe "token expiry in non-UTC database sessions" do
    for zone <- ["America/New_York"] do
      test "session expiry preserves UTC semantics in #{zone}" do
        Repo.query!("SET LOCAL TIME ZONE '#{unquote(zone)}'")
        user = insert_user()
        fresh = Accounts.generate_user_session_token(user)
        expired = Accounts.generate_user_session_token(user)
        offset_user_token(expired, -(60 * 24 + 1), :hour)

        assert {%{id: id}, _inserted_at} = Accounts.get_user_by_session_token(fresh)
        assert id == user.id
        assert Accounts.get_user_by_session_token(expired) == nil
      end

      test "magic-link expiry preserves UTC semantics in #{zone}" do
        Repo.query!("SET LOCAL TIME ZONE '#{unquote(zone)}'")
        user = insert_user()
        {fresh, _fresh_hash} = generate_user_magic_link_token(user)
        {expired, expired_hash} = generate_user_magic_link_token(user)
        offset_user_token(expired_hash, -60, :minute)

        assert %{id: id} = Accounts.get_user_by_magic_link_token(fresh)
        assert id == user.id
        assert Accounts.get_user_by_magic_link_token(expired) == nil
      end

      test "email-change expiry preserves UTC semantics in #{zone}" do
        Repo.query!("SET LOCAL TIME ZONE '#{unquote(zone)}'")
        user = insert_user()
        context = "change:#{user.email}"
        {fresh, fresh_row} = UserToken.build_email_token(user, context)
        {expired, expired_row} = UserToken.build_email_token(user, context)
        Repo.insert!(fresh_row)
        Repo.insert!(expired_row)
        offset_user_token(expired_row.token, -(7 * 24 + 1), :hour)

        assert {:ok, fresh_query} = UserToken.verify_change_email_token_query(fresh, context)
        assert %UserToken{user_id: id} = Repo.one(fresh_query)
        assert id == user.id
        assert {:ok, expired_query} = UserToken.verify_change_email_token_query(expired, context)
        assert Repo.one(expired_query) == nil
      end
    end
  end

  describe "token families" do
    test "email tokens retain their hash format, destination and null family" do
      user = insert_user()

      for context <- ["login", "change:old@example.com"] do
        {encoded, token} = UserToken.build_email_token(user, context)
        assert {:ok, bytes} = Base.url_decode64(encoded, padding: false)
        assert byte_size(bytes) == 32
        assert token.token == :crypto.hash(:sha256, bytes)
        assert {:ok, persisted} = Repo.insert(token)
        assert persisted.sent_to == user.email
        assert persisted.session_family_id == nil
        assert persisted.authenticated_at == nil
      end
    end
  end

  defp insert_user(attrs \\ %{}) do
    User
    |> struct!(
      Map.merge(
        %{handle: "user#{System.unique_integer([:positive])}", email: unique_user_email()},
        attrs
      )
    )
    |> Repo.insert!()
  end
end
