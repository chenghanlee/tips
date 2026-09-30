defmodule Tips.Accounts.IdentitySchemaTest do
  use Tips.DataCase, async: true

  alias Tips.Accounts
  alias Tips.Accounts.{User, UserToken}

  import Tips.AccountsFixtures

  describe "database identity constraints" do
    for handle <- ["ab", "_abc", "has space", "has.dot", "valid\n", String.duplicate("a", 31)] do
      test "rejects invalid handle #{inspect(handle)}" do
        assert_raise Ecto.ConstraintError, ~r/users_handle_chk/, fn ->
          insert_user(%{handle: unquote(handle)})
        end
      end
    end

    for email <- [
          "no-at",
          "two@@example.com",
          "has space@example.com",
          String.duplicate("a", 243) <> "@example.com"
        ] do
      test "rejects invalid email #{inspect(email, printable_limit: 40)}" do
        assert_raise Ecto.ConstraintError, ~r/users_email_chk/, fn ->
          insert_user(%{email: unquote(email)})
        end
      end
    end

    for {attrs, constraint} <- [
          {%{handle: nil}, "users_handle_del"},
          {%{email: nil}, "users_email_del"},
          {%{deleted_at: ~U[2026-09-21 00:00:00Z], email: nil}, "users_handle_del"},
          {%{deleted_at: ~U[2026-09-21 00:00:00Z], handle: nil}, "users_email_del"},
          {%{ban: :full}, "users_ban_chk"},
          {%{banned_at: ~U[2026-09-21 00:00:00Z]}, "users_ban_chk"}
        ] do
      test "rejects inconsistent identity state #{inspect(attrs)}" do
        assert_raise Ecto.ConstraintError, ~r/#{unquote(constraint)}/, fn ->
          insert_user(unquote(Macro.escape(attrs)))
        end
      end
    end

    test "rejects unknown roles in the database" do
      user = insert_user()

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("UPDATE users SET role = 'admin' WHERE id = $1", [user.id])
        end

      assert error.postgres.constraint == "users_role_vals"
    end

    test "rejects unknown bans in the database" do
      user = insert_user()

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("UPDATE users SET ban = 'partial', banned_at = $2 WHERE id = $1", [
            user.id,
            ~U[2026-09-21 00:00:00Z]
          ])
        end

      assert error.postgres.constraint == "users_ban_vals"
    end

    test "rejects case variants of a handle" do
      user = insert_user(%{handle: "MixedCase"})

      assert_raise Ecto.ConstraintError, ~r/users_handle_unique/, fn ->
        insert_user(%{handle: String.downcase(user.handle)})
      end
    end

    test "rejects case variants of an email" do
      user = insert_user()

      assert_raise Ecto.ConstraintError, ~r/users_email_unique/, fn ->
        insert_user(%{email: String.upcase(user.email)})
      end
    end

    test "accepts moderator and full ban, and allows deleted identities to be reused" do
      now = DateTime.utc_now(:second)
      user = insert_user(%{role: :moderator, ban: :full, banned_at: now})
      assert %{role: :moderator, ban: :full, banned_at: ^now} = Repo.reload!(user)

      assert {:ok, deleted} =
               user
               |> change(handle: nil, email: nil, deleted_at: now)
               |> Repo.update()

      assert %{handle: nil, email: nil, deleted_at: ^now} = Repo.reload!(deleted)
      assert %{handle: nil, email: nil} = insert_user(%{handle: nil, email: nil, deleted_at: now})

      assert %{handle: handle, email: email} =
               insert_user(%{handle: user.handle, email: user.email})

      assert handle == user.handle
      assert email == user.email
    end

    test "accepts the maximum handle and database email lengths" do
      handle = String.duplicate("a", 30)
      email = String.duplicate("a", 242) <> "@example.com"
      assert %{handle: ^handle, email: ^email} = insert_user(%{handle: handle, email: email})
    end
  end

  describe "registration boundary" do
    for handle <- [
          nil,
          "ab",
          "_abc",
          "has space",
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

    for handle <- ~w(admin moderator mod staff support deleted removed) do
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

      user = set_password(user)

      assert Accounts.get_user_by_email_and_password(" MIXED@EXAMPLE.COM ", valid_user_password()).id ==
               user.id
    end

    test "case-variant duplicate handle returns a changeset error" do
      insert_user(%{handle: "MixedCase"})

      assert {:error, changeset} =
               Accounts.register_user(%{handle: "mixedcase", email: unique_user_email()})

      assert %{handle: ["has already been taken"]} = errors_on(changeset)
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

    for space <- ["\u00A0", "\u2003", "\u3000", "\u0085"] do
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
    for zone <- ["UTC", "Asia/Taipei", "America/New_York"] do
      test "session expiry preserves UTC semantics in #{zone}" do
        Repo.query!("SET LOCAL TIME ZONE '#{unquote(zone)}'")
        user = insert_user()
        fresh = Accounts.generate_user_session_token(user)
        expired = Accounts.generate_user_session_token(user)
        offset_user_token(expired, -(14 * 24 + 1), :hour)

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
    test "session rows require a family" do
      user = insert_user()

      assert_raise Ecto.ConstraintError, ~r/users_tokens_session_family_chk/, fn ->
        Repo.insert!(%UserToken{
          user_id: user.id,
          token: :crypto.strong_rand_bytes(32),
          context: "session"
        })
      end
    end

    for context <- ["login", "change:old@example.com"] do
      test "#{context} rows reject a family" do
        user = insert_user()
        {_, token} = UserToken.build_email_token(user, unquote(context))

        assert_raise Ecto.ConstraintError, ~r/users_tokens_session_family_chk/, fn ->
          token |> struct!(session_family_id: Ecto.UUID.generate()) |> Repo.insert!()
        end
      end
    end

    test "session creation persists raw tokens, fresh families and current authentication recency" do
      recency = ~U[2026-09-20 12:34:56Z]
      user = insert_user() |> Map.put(:authenticated_at, recency)
      first = Accounts.generate_user_session_token(user)
      second = Accounts.generate_user_session_token(user)
      first_row = Repo.get_by!(UserToken, token: first)
      second_row = Repo.get_by!(UserToken, token: second)

      assert byte_size(first) == 32
      assert {:ok, family} = Ecto.UUID.cast(first_row.session_family_id)
      assert {:ok, other_family} = Ecto.UUID.cast(second_row.session_family_id)
      refute family == other_family
      assert DateTime.after?(first_row.authenticated_at, recency)
      assert DateTime.after?(second_row.authenticated_at, recency)

      assert {{_, 0}, "Etc/UTC"} =
               {first_row.inserted_at.microsecond, first_row.inserted_at.time_zone}
    end

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

    test "physical deletion cascades tokens and preserves another account's tokens" do
      user = insert_user()
      other = insert_user()
      Accounts.generate_user_session_token(user)
      survivor = Accounts.generate_user_session_token(other)
      {_, email_token} = UserToken.build_email_token(user, "login")
      Repo.insert!(email_token)

      assert {:ok, _} = Repo.delete(user)
      refute Repo.exists?(from token in UserToken, where: token.user_id == ^user.id)
      assert Repo.get_by!(UserToken, token: survivor).user_id == other.id
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
