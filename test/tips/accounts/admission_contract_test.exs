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

  # Representative Content callers. They take server-built context and business
  # attrs separately, and recheck eligibility on the locked account row.
  defmodule CallerExamples do
    import Ecto.Query

    alias Tips.Accounts
    alias Tips.Accounts.{Scope, SessionRef, User}
    alias Tips.Repo

    # LiveView event or controller action: scope comes from UserAuth, attrs from the client.
    def contribute(nil, _attrs), do: {:error, :unauthenticated}

    # Long-lived page: re-admit the private reference, then run the operation as above.
    def contribute(%SessionRef{} = ref, attrs) do
      with {:ok, scope} <- Accounts.readmit_scope(ref), do: contribute(scope, attrs)
    end

    def contribute(%Scope{user: %User{id: user_id}}, attrs) do
      Repo.transact(fn ->
        with :ok <- user_id |> lock_account() |> Accounts.check_eligibility(:contribute) do
          {:ok, %{author_id: user_id, title: attrs["title"]}}
        end
      end)
    end

    # Own deletion: a full ban does not deny it; ownership stays with Content.
    def delete_own(nil, _owner_id), do: {:error, :unauthenticated}

    def delete_own(%SessionRef{} = ref, owner_id) do
      with {:ok, scope} <- Accounts.readmit_scope(ref), do: delete_own(scope, owner_id)
    end

    def delete_own(%Scope{user: %User{id: user_id}}, owner_id) do
      Repo.transact(fn ->
        with :ok <- user_id |> lock_account() |> Accounts.check_eligibility(:delete_own_content),
             ^user_id <- owner_id do
          {:ok, :deleted}
        else
          {:error, reason} -> {:error, reason}
          _other_owner -> {:error, :forbidden}
        end
      end)
    end

    # Privileged read of one's own hidden item: fresh admission first, then the
    # owning operation's ownership check. It is not check_eligibility/2, so a
    # full ban does not deny it. This example hides existence from non-owners.
    def read_own_hidden(%SessionRef{} = ref, owner_id) do
      with {:ok, %Scope{user: %User{id: user_id}}} <- Accounts.readmit_scope(ref) do
        if user_id == owner_id, do: {:ok, :hidden_item}, else: {:error, :not_found}
      end
    end

    # Moderator-only read: fresh admission first, then the current role.
    def read_moderation_queue(%SessionRef{} = ref) do
      with {:ok, %Scope{user: %User{role: role}}} <- Accounts.readmit_scope(ref) do
        if role == :moderator, do: {:ok, :queue}, else: {:error, :forbidden}
      end
    end

    # Moderation action: fresh admission, then eligibility on the locked account.
    def moderate(%SessionRef{} = ref) do
      with {:ok, %Scope{user: %User{id: user_id}}} <- Accounts.readmit_scope(ref) do
        Repo.transact(fn -> moderate_locked(user_id) end)
      end
    end

    defp moderate_locked(user_id) do
      with :ok <- user_id |> lock_account() |> Accounts.check_eligibility(:moderate) do
        {:ok, :moderated}
      end
    end

    # Worker: no browser scope or session reference; reload committed state by id.
    def perform_worker(%{"user_id" => user_id}) do
      Repo.transact(fn ->
        with :ok <- user_id |> lock_account() |> Accounts.check_eligibility(:contribute) do
          {:ok, user_id}
        end
      end)
    end

    defp lock_account(user_id) do
      Repo.one!(from u in User, where: u.id == ^user_id, lock: "FOR NO KEY UPDATE")
    end
  end

  describe "one validity definition: generated session lookup" do
    test "a valid session row returns the account and token insertion time" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      user_id = user.id

      assert {%User{id: ^user_id}, %DateTime{}} = Accounts.get_user_by_session_token(token)
    end

    test "an expired session row does not authenticate" do
      token = Accounts.generate_user_session_token(user_fixture())
      set_token_inserted_at(token, days_ago(60))

      assert Accounts.get_user_by_session_token(token) == nil
    end

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

    test "consumers act as the admitted account, whatever identity the attrs carry", %{
      user: user,
      ref: ref
    } do
      other = user_fixture()
      author_id = user.id

      attrs = %{
        "title" => "Tip",
        "user_id" => other.id,
        "session_ref" => %{"user_id" => other.id}
      }

      assert {:ok, %{author_id: ^author_id}} = CallerExamples.contribute(ref, attrs)
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

    test "a moderator read follows the current role", %{user: user, ref: ref} do
      assert {:error, :forbidden} = CallerExamples.read_moderation_queue(ref)
      promoted = moderator(user)
      assert {:ok, :queue} = CallerExamples.read_moderation_queue(ref)
      update_user(promoted, role: :user)
      assert {:error, :forbidden} = CallerExamples.read_moderation_queue(ref)
    end
  end

  describe "banned owners retain reads and deletion while contributions/moderation fail" do
    test "a full ban committed after mount" do
      %{user: user, ref: ref} = admitted()
      %{ref: stranger_ref} = admitted()
      user |> moderator() |> ban()

      assert {:ok, :hidden_item} = CallerExamples.read_own_hidden(ref, user.id)
      assert {:ok, :queue} = CallerExamples.read_moderation_queue(ref)
      assert {:ok, :deleted} = CallerExamples.delete_own(ref, user.id)
      assert {:error, :forbidden} = CallerExamples.contribute(ref, %{"title" => "Tip"})
      assert {:error, :forbidden} = CallerExamples.moderate(ref)

      assert {:error, :not_found} = CallerExamples.read_own_hidden(stranger_ref, user.id)
      assert {:error, :forbidden} = CallerExamples.delete_own(stranger_ref, user.id)
    end

    test "an unconfirmed account cannot contribute but keeps its own deletion" do
      %{user: user, ref: ref} = admitted()
      update_user(user, confirmed_at: nil)

      assert {:error, :unconfirmed} = CallerExamples.contribute(ref, %{"title" => "Tip"})
      assert {:ok, :deleted} = CallerExamples.delete_own(ref, user.id)
    end

    test "a revoked or deleted session reaches no privileged branch" do
      %{user: user, token: token, ref: ref} = admitted()
      %{user: deleted, ref: deleted_ref} = admitted()
      assert {:ok, [_family]} = Accounts.revoke_user_session_family(token)
      soft_delete(deleted)

      for {ref, owner_id} <- [{ref, user.id}, {deleted_ref, deleted.id}] do
        assert {:error, :unauthenticated} = CallerExamples.read_own_hidden(ref, owner_id)
        assert {:error, :unauthenticated} = CallerExamples.read_moderation_queue(ref)
        assert {:error, :unauthenticated} = CallerExamples.delete_own(ref, owner_id)
        assert {:error, :unauthenticated} = CallerExamples.contribute(ref, %{"title" => "Tip"})
        assert {:error, :unauthenticated} = CallerExamples.moderate(ref)
      end
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

    test "a session reference holds only the token row id and mounted user id" do
      assert %SessionRef{token_id: 1, user_id: 2} =
               ref = struct!(SessionRef, token_id: 1, user_id: 2)

      assert ref |> Map.from_struct() |> Map.keys() |> Enum.sort() == [:token_id, :user_id]
      assert_raise ArgumentError, fn -> struct!(SessionRef, token_id: 1) end
      assert_raise ArgumentError, fn -> struct!(SessionRef, user_id: 2) end
    end

    test "scopes and session references have no automatic public serialization" do
      scope = Scope.for_user(user_fixture())
      ref = struct!(SessionRef, token_id: 1, user_id: scope.user.id)

      for value <- [scope, ref] do
        assert_raise Protocol.UndefinedError, fn -> JSON.encode!(value) end
        assert_raise Protocol.UndefinedError, fn -> Jason.encode!(value) end
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

    test "Content callers ignore client identity in business attrs" do
      scope = Scope.for_user(user_fixture())
      other = user_fixture()
      author_id = scope.user.id
      attrs = %{"title" => "Tip", "user_id" => other.id, "author_id" => other.id}

      assert {:ok, %{author_id: ^author_id, title: "Tip"}} =
               CallerExamples.contribute(scope, attrs)

      assert {:error, :unauthenticated} = CallerExamples.contribute(nil, attrs)
    end
  end

  describe "operation eligibility matrix" do
    @matrix [
      {:confirmed,
       [contribute: :ok, moderate: :forbidden, delete_own_content: :ok, delete_account: :ok]},
      {:unconfirmed,
       [
         contribute: :unconfirmed,
         moderate: :forbidden,
         delete_own_content: :ok,
         delete_account: :ok
       ]},
      {:full_ban,
       [
         contribute: :forbidden,
         moderate: :forbidden,
         delete_own_content: :ok,
         delete_account: :ok
       ]},
      {:moderator,
       [contribute: :ok, moderate: :ok, delete_own_content: :ok, delete_account: :ok]},
      {:unconfirmed_moderator,
       [
         contribute: :unconfirmed,
         moderate: :unconfirmed,
         delete_own_content: :ok,
         delete_account: :ok
       ]},
      {:banned_moderator,
       [
         contribute: :forbidden,
         moderate: :forbidden,
         delete_own_content: :ok,
         delete_account: :ok
       ]},
      {:deleted,
       [
         contribute: :unauthenticated,
         moderate: :unauthenticated,
         delete_own_content: :unauthenticated,
         delete_account: :unauthenticated
       ]}
    ]

    for {state, expectations} <- @matrix, {operation, outcome} <- expectations do
      result = if outcome == :ok, do: :ok, else: {:error, outcome}

      test "#{state} account: #{operation} -> #{outcome}" do
        user = account(unquote(state))

        assert Accounts.check_eligibility(user, unquote(operation)) ==
                 unquote(Macro.escape(result))
      end
    end
  end

  describe "operation outcomes" do
    test "contribution rechecks the locked account, so a scope admitted before a ban is refused" do
      user = user_fixture()
      scope = Scope.for_user(user)
      ban(user)

      assert {:error, :forbidden} = CallerExamples.contribute(scope, %{"title" => "Tip"})
    end

    test "a full-banned author may still delete their own content, but not another's" do
      user = user_fixture()
      scope = Scope.for_user(user)
      ban(user)

      assert {:ok, :deleted} = CallerExamples.delete_own(scope, user.id)
      assert {:error, :forbidden} = CallerExamples.delete_own(scope, user_fixture().id)
      assert {:error, :unauthenticated} = CallerExamples.delete_own(nil, user.id)
    end

    test "a full-banned moderator loses moderation actions but the session still admits the moderator role" do
      moderator = user_fixture() |> moderator() |> ban()
      token = Accounts.generate_user_session_token(moderator)

      assert {:error, :forbidden} = Accounts.check_eligibility(moderator, :moderate)

      assert {:ok, %Scope{user: %User{role: :moderator, ban: :full}}, _ref, _inserted_at} =
               Accounts.get_scope_by_session_token(token)
    end

    test "account deletion keeps its recent sign-in requirement for banned accounts" do
      user = user_fixture() |> ban()
      recent = %{user | authenticated_at: DateTime.utc_now(:second)}
      stale = %{user | authenticated_at: DateTime.add(DateTime.utc_now(:second), -1, :hour)}

      assert :ok = Accounts.check_eligibility(recent, :delete_account)
      assert Accounts.sudo_mode?(recent)
      refute Accounts.sudo_mode?(stale)
    end
  end

  describe "workers reload business eligibility without browser session" do
    test "a worker runs after every session of the account is revoked" do
      %{user: user, ref: ref} = admitted()
      user_id = user.id
      assert {:ok, [_family]} = Accounts.revoke_user_session_families(user)

      assert {:error, :unauthenticated} = Accounts.readmit_scope(ref)
      assert {:ok, ^user_id} = CallerExamples.perform_worker(%{"user_id" => user_id})
    end

    test "a worker follows committed bans and deletion, not the admitting session" do
      %{user: user} = admitted()
      args = %{"user_id" => user.id}

      banned = ban(user)
      assert {:error, :forbidden} = CallerExamples.perform_worker(args)

      banned |> update_user(ban: nil, banned_at: nil) |> soft_delete()
      assert {:error, :unauthenticated} = CallerExamples.perform_worker(args)
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

  defp account(:confirmed), do: user_fixture()
  defp account(:unconfirmed), do: unconfirmed_user_fixture()
  defp account(:full_ban), do: user_fixture() |> ban()
  defp account(:moderator), do: user_fixture() |> moderator()
  defp account(:unconfirmed_moderator), do: unconfirmed_user_fixture() |> moderator()
  defp account(:banned_moderator), do: user_fixture() |> moderator() |> ban()
  defp account(:deleted), do: user_fixture() |> soft_delete()

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
