defmodule Tips.Accounts.AdmissionContractTest do
  @moduledoc """
  Contract evidence for #33. See the "Admission contract" section of `Tips.Accounts`.

  Tests named "gap for #47" characterize current generated behavior that runtime
  admission must change; they are not claims that #33 enforces it.
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
    alias Tips.Accounts.{Scope, User}
    alias Tips.Repo

    # LiveView event or controller action: scope comes from UserAuth, attrs from the client.
    def contribute(nil, _attrs), do: {:error, :unauthenticated}

    def contribute(%Scope{user: %User{id: user_id}}, attrs) do
      Repo.transact(fn ->
        with :ok <- user_id |> lock_account() |> Accounts.check_eligibility(:contribute) do
          {:ok, %{author_id: user_id, title: attrs["title"]}}
        end
      end)
    end

    # Own deletion: a full ban does not deny it; ownership stays with Content.
    def delete_own(nil, _owner_id), do: {:error, :unauthenticated}

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

    # Privileged read of one's own hidden item. The scope must already have
    # passed fresh admission (#47 readmit_scope/1); this example does not fake
    # that step. The owning operation checks ownership/role/visibility, not
    # check_eligibility/2, so a full ban does not deny it. It chooses :not_found
    # or :forbidden for non-owners; this example hides existence.
    def read_own_hidden(nil, _owner_id), do: {:error, :unauthenticated}

    def read_own_hidden(%Scope{user: %User{id: user_id}}, user_id), do: {:ok, :hidden_item}
    def read_own_hidden(%Scope{}, _owner_id), do: {:error, :not_found}

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
      set_token_inserted_at(token, DateTime.add(DateTime.utc_now(:second), -15, :day))

      assert Accounts.get_user_by_session_token(token) == nil
    end

    test "a revoked (deleted) session row does not authenticate" do
      token = Accounts.generate_user_session_token(user_fixture())
      assert :ok = Accounts.delete_user_session_token(token)

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

    test "gap for #47: the generated lookup still returns a deleted account's surviving row" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      soft_delete(user)

      assert {%User{deleted_at: %DateTime{}}, _} = Accounts.get_user_by_session_token(token)
      assert {:error, :unauthenticated} = Accounts.check_eligibility(reload(user), :contribute)
    end
  end

  describe "private identity boundary" do
    test "a scope carries only the current account, never a bearer token or row reference" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      {session_user, _} = Accounts.get_user_by_session_token(token)

      assert %Scope{user: ^session_user} = scope = Scope.for_user(session_user)
      assert scope |> Map.from_struct() |> Map.keys() == [:user]
      refute inspect(scope, limit: :infinity) =~ inspect(token, limit: :infinity)
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

    test "a full-banned owner may still read their own hidden item; others may not" do
      # Stand-in for #47 fresh admission: the real generated lookup after the ban.
      user = user_fixture() |> ban()
      token = Accounts.generate_user_session_token(user)
      {%User{ban: :full} = admitted, _} = Accounts.get_user_by_session_token(token)
      scope = Scope.for_user(admitted)

      assert {:ok, :hidden_item} = CallerExamples.read_own_hidden(scope, user.id)

      assert {:error, :not_found} =
               CallerExamples.read_own_hidden(Scope.for_user(user_fixture()), user.id)

      assert {:error, :unauthenticated} = CallerExamples.read_own_hidden(nil, user.id)
    end

    test "a full-banned moderator loses moderation actions but the session still admits the moderator role" do
      moderator = user_fixture() |> moderator() |> ban()
      token = Accounts.generate_user_session_token(moderator)

      assert {:error, :forbidden} = Accounts.check_eligibility(moderator, :moderate)

      assert {%User{role: :moderator, ban: :full}, _} =
               Accounts.get_user_by_session_token(token)
    end

    test "account deletion keeps its recent sign-in requirement for banned accounts" do
      user = user_fixture() |> ban()
      recent = %{user | authenticated_at: DateTime.utc_now(:second)}
      stale = %{user | authenticated_at: DateTime.add(DateTime.utc_now(:second), -1, :hour)}

      assert :ok = Accounts.check_eligibility(recent, :delete_account)
      assert Accounts.sudo_mode?(recent)
      refute Accounts.sudo_mode?(stale)
    end

    test "workers reload committed account state by id without a browser scope" do
      user = user_fixture()
      user_id = user.id

      assert {:ok, ^user_id} = CallerExamples.perform_worker(%{"user_id" => user_id})
      ban(user)
      assert {:error, :forbidden} = CallerExamples.perform_worker(%{"user_id" => user_id})
    end
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

  defp reload(user), do: Repo.reload!(user)

  defp set_token_inserted_at(token, inserted_at) do
    assert {1, nil} =
             Repo.update_all(from(t in UserToken, where: t.token == ^token),
               set: [inserted_at: inserted_at]
             )
  end
end
