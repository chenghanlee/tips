defmodule Tips.Accounts.AdmissionContractTest do
  @moduledoc """
  Contract evidence for #33 and #47. See the "Admission contract" section of `Tips.Accounts`.
  """
  use TipsWeb.ConnCase, async: true

  import Ecto.Query
  import Tips.AccountsFixtures

  alias Phoenix.LiveView
  alias Tips.Accounts
  alias Tips.Accounts.{Scope, SessionRef, User, UserToken}
  alias Tips.Repo
  alias TipsWeb.UserAuth

  describe "one validity definition: generated session lookup" do
    test "a revoked (deleted) session row does not authenticate" do
      token = Accounts.generate_user_session_token(user_fixture())
      assert {:ok, [_family]} = Accounts.revoke_user_session_family(token)

      assert Accounts.get_user_by_session_token(token) == nil
    end

    test "a token row in another context does not authenticate as a session" do
      user = user_fixture()
      raw = :crypto.strong_rand_bytes(32)

      Repo.insert!(%UserToken{
        token: raw,
        context: "login",
        sent_to: user.email,
        user_id: user.id
      })

      assert Accounts.get_user_by_session_token(raw) == nil
    end

    test "a full ban keeps sign-in: the session still authenticates" do
      user = user_fixture() |> ban()
      token = Accounts.generate_user_session_token(user)

      assert {%User{ban: :full}, _} = Accounts.get_user_by_session_token(token)
    end

    test "a deleted account's surviving session row does not authenticate" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      soft_delete(user)

      assert Accounts.get_user_by_session_token(token) == nil
      assert {:error, :unauthenticated} = Accounts.get_scope_by_session_token(token)
    end

    test "the bearer lookup returns the scope, a private row reference and the insertion time" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      %UserToken{id: token_id, inserted_at: inserted_at, authenticated_at: authenticated_at} =
        Repo.get_by!(UserToken, token: token)

      assert {:ok, %Scope{user: admitted}, ref, ^inserted_at} =
               Accounts.get_scope_by_session_token(token)

      assert %User{authenticated_at: ^authenticated_at} = admitted
      assert admitted.id == user.id
      assert ref == %SessionRef{token_id: token_id, user_id: user.id}
      assert {admitted, inserted_at} == Accounts.get_user_by_session_token(token)
    end

    test "malformed bearer values fail closed" do
      for value <- [nil, 1, %{}, [], :token, "", "unknown"] do
        assert {:error, :unauthenticated} = Accounts.get_scope_by_session_token(value)
      end
    end
  end

  describe "readmission rejects expired/revoked/wrong-context/deleted-account sessions" do
    setup do: admitted()

    test "a current session re-admits its account", %{user: user, ref: ref} do
      user_id = user.id
      assert {:ok, %Scope{user: %User{id: ^user_id}}} = Accounts.readmit_scope(ref)
    end

    test "the shared expiry boundary applies to both lookups", %{token: token, ref: ref} do
      set_token_inserted_at(token, days_ago(60, 60))
      assert {:ok, %Scope{}} = Accounts.readmit_scope(ref)
      assert {:ok, %Scope{}, ^ref, _} = Accounts.get_scope_by_session_token(token)

      set_token_inserted_at(token, days_ago(60))
      assert {:error, :unauthenticated} = Accounts.readmit_scope(ref)
      assert {:error, :unauthenticated} = Accounts.get_scope_by_session_token(token)
    end

    test "a revoked family is rejected, another family of the account is not", %{
      user: user,
      token: token,
      ref: ref
    } do
      other_browser = Accounts.generate_user_session_token(user)
      {:ok, _scope, other_ref, _} = Accounts.get_scope_by_session_token(other_browser)
      {:ok, sibling} = Accounts.renew_user_session_token(user, token)
      {:ok, _scope, sibling_ref, _} = Accounts.get_scope_by_session_token(sibling)

      assert {:ok, [_family]} = Accounts.revoke_user_session_family(token)

      assert {:error, :unauthenticated} = Accounts.readmit_scope(ref)
      assert {:error, :unauthenticated} = Accounts.readmit_scope(sibling_ref)
      assert {:ok, %Scope{}} = Accounts.readmit_scope(other_ref)
    end

    test "a row in another context is rejected", %{token: token, ref: ref} do
      Repo.update_all(from(t in UserToken, where: t.token == ^token),
        set: [context: "login", session_family_id: nil, authenticated_at: nil]
      )

      assert {:error, :unauthenticated} = Accounts.readmit_scope(ref)
    end

    test "a deleted account is rejected while its row survives", %{user: user, ref: ref} do
      soft_delete(user)

      assert Repo.get!(UserToken, ref.token_id)
      assert {:error, :unauthenticated} = Accounts.readmit_scope(ref)
    end
  end

  describe "readmission binds row to mounted account and rejects forged references" do
    setup do: admitted()

    test "the row id and the mounted user id must both match", %{user: user, ref: ref} do
      %{user: other, ref: other_ref} = admitted()

      # Another account's id on my row, my id on another account's row, and a missing row.
      assert {:error, :unauthenticated} = Accounts.readmit_scope(%{ref | user_id: other.id})
      assert {:error, :unauthenticated} = Accounts.readmit_scope(%{other_ref | user_id: user.id})
      assert {:error, :unauthenticated} = Accounts.readmit_scope(%{ref | token_id: 0})

      assert {:error, :unauthenticated} =
               Accounts.readmit_scope(%{ref | token_id: ref.token_id + 1_000_000})
    end

    test "a non-session row of the same account is not a session reference", %{user: user} do
      {_encoded, hashed} = generate_user_magic_link_token(user)
      %UserToken{id: login_row_id} = Repo.get_by!(UserToken, token: hashed)

      assert {:error, :unauthenticated} =
               Accounts.readmit_scope(%SessionRef{token_id: login_row_id, user_id: user.id})
    end

    test "malformed and client-shaped references fail closed", %{token: token, ref: ref} do
      %SessionRef{token_id: token_id, user_id: user_id} = ref

      for forged <- [
            nil,
            token,
            token_id,
            {token_id, user_id},
            %{token_id: token_id, user_id: user_id},
            %{"token_id" => token_id, "user_id" => user_id},
            %SessionRef{token_id: nil, user_id: user_id},
            %SessionRef{token_id: token_id, user_id: nil},
            %SessionRef{token_id: Integer.to_string(token_id), user_id: user_id},
            %SessionRef{token_id: token_id, user_id: Integer.to_string(user_id)},
            %SessionRef{token_id: -token_id, user_id: user_id},
            %SessionRef{token_id: token_id * 1.0, user_id: user_id},
            %SessionRef{token_id: 9_223_372_036_854_775_808, user_id: user_id},
            %SessionRef{token_id: token_id, user_id: 9_223_372_036_854_775_808}
          ] do
        assert {:error, :unauthenticated} = Accounts.readmit_scope(forged),
               "admitted #{inspect(forged)}"
      end
    end
  end

  describe "readmission reloads role, confirmation, ban and authentication recency" do
    setup do: admitted()

    test "current role, ban and confirmation replace the mounted state", %{user: user, ref: ref} do
      assert {:ok, %Scope{user: %User{role: :user, ban: nil, confirmed_at: %DateTime{}}}} =
               Accounts.readmit_scope(ref)

      banned = user |> moderator() |> ban()

      assert {:ok, %Scope{user: %User{role: :moderator, ban: :full}}} =
               Accounts.readmit_scope(ref)

      update_user(banned, role: :user, ban: nil, banned_at: nil, confirmed_at: nil)

      assert {:ok, %Scope{user: %User{role: :user, ban: nil, confirmed_at: nil}}} =
               Accounts.readmit_scope(ref)
    end

    test "authentication recency comes from the referenced row", %{
      user: user,
      token: token,
      ref: ref
    } do
      stale = DateTime.add(DateTime.utc_now(:second), -1, :hour)
      override_token_authenticated_at(token, stale)
      _fresh_other_browser = Accounts.generate_user_session_token(user)

      assert {:ok, %Scope{user: %User{authenticated_at: ^stale} = admitted}} =
               Accounts.readmit_scope(ref)

      refute Accounts.sudo_mode?(admitted)
    end
  end

  describe "private identity boundary" do
    test "a scope carries only the current account, never a bearer token or row reference" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      {:ok, scope, ref, _inserted_at} = Accounts.get_scope_by_session_token(token)

      assert scope |> Map.from_struct() |> Map.keys() == [:user]
      assert ref |> Map.from_struct() |> Map.keys() |> Enum.sort() == [:token_id, :user_id]

      for value <- [scope, ref] do
        assert :binary.match(:erlang.term_to_binary(value), token) == :nomatch
      end

      assert Scope.for_user(nil) == nil
    end

    test "Scope.for_user/1 rejects client-shaped identity" do
      user = user_fixture()

      for payload <- [%{"id" => user.id}, %{id: user.id}, user.id, Map.from_struct(user)] do
        assert_raise FunctionClauseError, fn -> Scope.for_user(payload) end
      end
    end

    test "controllers build the scope from the server session, never from params", %{conn: conn} do
      user = user_fixture()
      other = user_fixture()
      token = Accounts.generate_user_session_token(user)
      user_id = user.id
      injected = %{"user_id" => other.id, "current_scope" => %{"user" => %{"id" => other.id}}}

      conn =
        conn
        |> Map.replace!(:secret_key_base, TipsWeb.Endpoint.config(:secret_key_base))
        |> init_test_session(%{user_token: token})
        |> Map.put(:params, injected)
        |> UserAuth.fetch_current_scope_for_user([])

      assert %Scope{user: %User{id: ^user_id}} = conn.assigns.current_scope

      anonymous =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, injected)
        |> UserAuth.fetch_current_scope_for_user([])

      assert anonymous.assigns.current_scope == nil
    end

    test "LiveViews build the scope from the server session, never from params" do
      user = user_fixture()
      other = user_fixture()
      token = Accounts.generate_user_session_token(user)
      user_id = user.id
      params = %{"user_id" => other.id}

      assert {:cont, socket} =
               UserAuth.on_mount(
                 :mount_current_scope,
                 params,
                 %{"user_token" => token},
                 %LiveView.Socket{}
               )

      assert %Scope{user: %User{id: ^user_id}} = socket.assigns.current_scope

      assert {:cont, anonymous} =
               UserAuth.on_mount(:mount_current_scope, params, %{}, %LiveView.Socket{})

      assert anonymous.assigns.current_scope == nil
    end
  end

  # A signed-in account as a LiveView holds it: the bearer stays in the cookie session.
  defp admitted do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)
    {:ok, _scope, ref, _inserted_at} = Accounts.get_scope_by_session_token(token)
    %{user: user, token: token, ref: ref}
  end

  defp days_ago(days, closer_seconds \\ 0) do
    DateTime.utc_now(:second) |> DateTime.add(-days, :day) |> DateTime.add(closer_seconds)
  end

  defp ban(user),
    do: update_user(user, ban: :full, banned_at: DateTime.utc_now(:second))

  defp moderator(user), do: update_user(user, role: :moderator)

  defp soft_delete(user),
    do: update_user(user, handle: nil, email: nil, deleted_at: DateTime.utc_now(:second))

  defp update_user(user, changes), do: user |> Ecto.Changeset.change(changes) |> Repo.update!()

  defp set_token_inserted_at(token, inserted_at) do
    assert {1, nil} =
             Repo.update_all(from(t in UserToken, where: t.token == ^token),
               set: [inserted_at: inserted_at]
             )
  end
end
