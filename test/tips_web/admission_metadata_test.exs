defmodule TipsWeb.AdmissionMetadataTest do
  @moduledoc """
  Representative HTTP and LiveView callers of `Tips.AdmissionLimiter`.

  The callers below are test fixtures, not product routes: feature callers ship
  with their own issues. Their identity paths are real: `TipsWeb.ClientIdentity`,
  `TipsWeb.UserAuth` scope construction and the endpoint's configured LiveView
  transport `connect_info`. Their side effects are real login tokens and mail
  from `Tips.Accounts`; the Tip insert and the provider message stand in for
  future Content writes and upload provider requests.
  """
  use TipsWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Tips.AccountsFixtures
  import Tips.AdmissionFixtures

  alias Phoenix.Socket.Transport
  alias Tips.Accounts
  alias Tips.Accounts.{Scope, UserToken}
  alias Tips.AdmissionLimiter
  alias Tips.Content.Tip
  alias Tips.Repo

  defmodule Caller do
    @moduledoc "Shared caller steps: admit, then run the side effect only on `:ok`."

    alias Tips.Accounts
    alias Tips.AdmissionLimiter

    def request_login(email, client_ip, limiter) do
      with {:ok, ip} <- client_ip,
           :ok <- AdmissionLimiter.check_auth(email, ip, limiter) do
        if user = Accounts.get_user_by_email(email) do
          Accounts.deliver_login_instructions(user, &"/users/log-in/#{&1}")
        end

        :ok
      end
    end

    # Content writes are not implemented yet; the Tip fixture stands in for one.
    def write(scope, limiter) do
      with :ok <- AdmissionLimiter.check_write(scope, limiter) do
        Tips.ContentFixtures.tip_fixture(scope.user)
        :ok
      end
    end

    # Upload provider requests are not implemented yet; a message stands in for one.
    def upload(scope, limiter, provider) do
      with :ok <- AdmissionLimiter.check_upload(scope, limiter) do
        send(provider, {:provider_request, scope.user.id})
        :ok
      end
    end

    def describe(:ok), do: "ok"
    def describe({:error, {reason, retry}}), do: "#{reason} #{retry}"
    def describe({:error, reason}), do: "#{reason}"
  end

  defmodule HttpCaller do
    @moduledoc "Controller-style caller: identity from the conn, scope from `TipsWeb.UserAuth`."

    import Plug.Conn

    alias TipsWeb.AdmissionMetadataTest.Caller
    alias TipsWeb.ClientIdentity

    def call(conn, action, limiter, provider \\ nil) do
      conn = TipsWeb.UserAuth.fetch_current_scope_for_user(conn, [])

      result =
        case action do
          :request_login ->
            Caller.request_login(conn.params["email"], ClientIdentity.from_conn(conn), limiter)

          :write ->
            Caller.write(conn.assigns.current_scope, limiter)

          :upload ->
            Caller.upload(conn.assigns.current_scope, limiter, provider)
        end

      respond(conn, result)
    end

    defp respond(conn, :ok), do: send_resp(conn, 200, "ok")

    defp respond(conn, {:error, {_reason, retry}} = result) do
      conn
      |> put_resp_header("retry-after", Integer.to_string(retry))
      |> send_resp(429, Caller.describe(result))
    end

    defp respond(conn, result), do: send_resp(conn, 400, Caller.describe(result))
  end

  defmodule LiveCaller do
    @moduledoc "LiveView caller: identity from connect info at mount, scope from `TipsWeb.UserAuth`."
    use Phoenix.LiveView

    alias TipsWeb.AdmissionMetadataTest.Caller
    alias TipsWeb.ClientIdentity

    on_mount {TipsWeb.UserAuth, :mount_current_scope}

    @impl true
    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         client_ip: ClientIdentity.from_socket(socket),
         limiter: session["limiter"],
         provider: session["provider"],
         result: nil
       )}
    end

    @impl true
    def render(assigns), do: ~H|<p id="result">{@result}</p>|

    @impl true
    def handle_event("request_login", %{"email" => email}, socket) do
      reply(socket, Caller.request_login(email, socket.assigns.client_ip, socket.assigns.limiter))
    end

    def handle_event("write", _params, socket) do
      reply(socket, Caller.write(socket.assigns.current_scope, socket.assigns.limiter))
    end

    def handle_event("upload", _params, socket) do
      %{current_scope: scope, limiter: limiter, provider: provider} = socket.assigns
      reply(socket, Caller.upload(scope, limiter, provider))
    end

    defp reply(socket, result), do: {:noreply, assign(socket, result: Caller.describe(result))}
  end

  @forged %{
    "ip" => "203.0.113.7",
    "remote_ip" => "203.0.113.7",
    "peer_data" => %{"address" => "203.0.113.7"},
    "user_id" => "1"
  }

  defp http(action, params, peer, limiter, opts \\ []) do
    :post
    |> build_conn("/", params)
    |> init_test_session(%{})
    |> then(&if(user = opts[:user], do: log_in_user(&1, user), else: &1))
    |> Map.put(:remote_ip, peer)
    |> put_req_header(
      "x-forwarded-for",
      "203.0.113.#{rem(System.unique_integer([:positive]), 250)}"
    )
    |> HttpCaller.call(action, limiter, opts[:provider])
  end

  # Build connect info exactly as the configured LiveView transport does.
  defp live_connect(transport, peer, limiter, opts \\ []) do
    {"/live", Phoenix.LiveView.Socket, socket_opts} =
      List.keyfind(TipsWeb.Endpoint.__sockets__(), "/live", 0)

    module = %{websocket: Phoenix.Transports.WebSocket, longpoll: Phoenix.Transports.LongPoll}

    keys =
      socket_opts
      |> Keyword.fetch!(transport)
      |> Transport.load_config(module[transport])
      |> Keyword.fetch!(:connect_info)
      |> Kernel.--(Keyword.get(opts, :drop_keys, []))

    transport_conn =
      build_conn()
      |> Plug.Test.put_peer_data(%{address: peer, port: 40_000, ssl_cert: nil})
      |> put_req_header("x-forwarded-for", "203.0.113.9")
      |> put_req_header("x-real-ip", "203.0.113.9")

    # LiveViewTest supplies the signed session itself; drop the cookie-less nil one.
    connect_info =
      transport_conn
      |> Transport.connect_info(TipsWeb.Endpoint, keys, check_csrf: false)
      |> Map.delete(:session)

    session =
      Map.merge(%{"limiter" => limiter, "provider" => self()}, Keyword.get(opts, :session, %{}))

    {:ok, view, _html} =
      build_conn()
      |> put_private(:live_view_connect_info, connect_info)
      |> live_isolated(LiveCaller, session: session, connect_params: @forged)

    view
  end

  defp live_event(view, event, params) do
    view |> render_click(event, Map.merge(@forged, params)) |> result()
  end

  defp result(html),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query("#result") |> LazyHTML.text()

  defp login_tokens(user) do
    Repo.aggregate(
      from(t in UserToken, where: t.user_id == ^user.id and t.context == "login"),
      :count
    )
  end

  @peer_a {192, 0, 2, 10}
  @peer_b {192, 0, 2, 20}
  @peer_c {192, 0, 2, 30}

  describe "auth buckets across transports" do
    test "HTTP and connected LiveView share normalized auth buckets" do
      %{limiter: limiter} = start_limiter(auth_destination: {3, 60_000}, auth_ip: {99, 60_000})

      conn = http(:request_login, %{"email" => "Alice@Example.com"}, @peer_a, limiter)
      assert conn.status == 200

      websocket = live_connect(:websocket, @peer_a, limiter)
      assert live_event(websocket, "request_login", %{"email" => "  alice@example.COM "}) == "ok"

      longpoll = live_connect(:longpoll, @peer_b, limiter)
      assert live_event(longpoll, "request_login", %{"email" => "ALICE@example.com\n"}) == "ok"

      # A distinct peer still shares the destination bucket.
      conn = http(:request_login, %{"email" => "alice@example.com"}, @peer_c, limiter)
      assert conn.status == 429
      assert [retry] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry) in 1..60
    end

    test "the same peer shares the IP bucket across HTTP and LiveView" do
      %{limiter: limiter} = start_limiter(auth_destination: {99, 60_000}, auth_ip: {2, 60_000})

      assert http(:request_login, %{"email" => "one@example.com"}, @peer_a, limiter).status == 200

      websocket = live_connect(:websocket, @peer_a, limiter)
      assert live_event(websocket, "request_login", %{"email" => "two@example.com"}) == "ok"

      assert live_event(websocket, "request_login", %{"email" => "three@example.com"}) =~
               "rate_limited"

      longpoll = live_connect(:longpoll, @peer_b, limiter)
      assert live_event(longpoll, "request_login", %{"email" => "three@example.com"}) == "ok"
    end
  end

  describe "trusted identity" do
    test "forwarded headers and client fields cannot replace transport identity" do
      %{limiter: limiter} = start_limiter(auth_destination: {99, 60_000}, auth_ip: {3, 60_000})

      # Every request forges a new forwarded address and client fields; all count against peer A.
      assert http(:request_login, Map.put(@forged, "email", "a@example.com"), @peer_a, limiter).status ==
               200

      for transport <- [:websocket, :longpoll] do
        view = live_connect(transport, @peer_a, limiter)
        assert live_event(view, "request_login", %{"email" => "#{transport}@example.com"}) == "ok"
      end

      assert http(:request_login, Map.put(@forged, "email", "d@example.com"), @peer_a, limiter).status ==
               429

      # The forged address itself was never charged.
      assert :ok = AdmissionLimiter.check_auth("e@example.com", {203, 0, 113, 7}, limiter)
      assert :ok = AdmissionLimiter.check_auth("e@example.com", {203, 0, 113, 9}, limiter)
    end

    test "missing peer metadata fails closed" do
      %{limiter: limiter} = start_limiter()
      user = user_fixture()

      for transport <- [:websocket, :longpoll] do
        view = live_connect(transport, @peer_a, limiter, drop_keys: [:peer_data])
        assert live_event(view, "request_login", %{"email" => user.email}) == "invalid_identity"
      end

      conn = http(:request_login, %{"email" => user.email}, nil, limiter)
      assert conn.status == 400
      assert login_tokens(user) == 0
      assert entry_count(limiter) == 0
    end

    test "server scope controls write and upload identity despite forged params" do
      %{limiter: limiter} = start_limiter(write: {2, 60_000}, upload: {1, 60_000})
      user = user_fixture()
      other = user_fixture()
      forged = %{"user_id" => to_string(other.id), "scope" => %{"user" => %{"id" => other.id}}}
      token = Accounts.generate_user_session_token(user)

      assert http(:write, forged, @peer_a, limiter, user: user).status == 200

      view = live_connect(:websocket, @peer_b, limiter, session: %{"user_token" => token})
      assert live_event(view, "write", forged) == "ok"
      assert live_event(view, "write", forged) =~ "rate_limited"
      assert live_event(view, "upload", forged) == "ok"
      assert_received {:provider_request, user_id} when user_id == user.id
      assert live_event(view, "upload", forged) =~ "rate_limited"

      assert [user.id, user.id] == Repo.all(from t in Tip, select: t.user_id)

      # The forged account kept its whole budget.
      other_scope = Scope.for_user(other)
      assert :ok = AdmissionLimiter.check_write(other_scope, limiter)
      assert :ok = AdmissionLimiter.check_write(other_scope, limiter)
      assert :ok = AdmissionLimiter.check_upload(other_scope, limiter)

      # Anonymous callers have no account identity to charge.
      anonymous = live_connect(:longpoll, @peer_b, limiter)
      assert live_event(anonymous, "write", forged) == "invalid_identity"
      assert http(:write, forged, @peer_a, limiter).status == 400
    end

    test "denial prevents token provider and mutation side effects" do
      %{limiter: limiter} =
        start_limiter(auth_destination: {1, 60_000}, write: {1, 60_000}, upload: {1, 60_000})

      user = user_fixture()
      # user_fixture confirms the account through its own login mail.
      assert_email_sent()

      assert http(:request_login, %{"email" => user.email}, @peer_a, limiter).status == 200
      assert login_tokens(user) == 1
      assert_email_sent()

      view = live_connect(:websocket, @peer_b, limiter)
      assert live_event(view, "request_login", %{"email" => user.email}) =~ "rate_limited"
      assert http(:request_login, %{"email" => user.email}, @peer_c, limiter).status == 429
      assert login_tokens(user) == 1
      assert_no_email_sent()

      as_user = [user: user, provider: self()]
      assert http(:write, %{}, @peer_a, limiter, as_user).status == 200
      assert http(:write, %{}, @peer_a, limiter, as_user).status == 429
      assert Repo.aggregate(Tip, :count) == 1

      assert http(:upload, %{}, @peer_a, limiter, as_user).status == 200
      assert_received {:provider_request, _}
      assert http(:upload, %{}, @peer_a, limiter, as_user).status == 429
      refute_received {:provider_request, _}
    end
  end
end
