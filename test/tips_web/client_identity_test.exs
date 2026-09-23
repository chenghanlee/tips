defmodule TipsWeb.ClientIdentityTest do
  use TipsWeb.ConnCase, async: true

  alias TipsWeb.ClientIdentity

  @forged_headers [
    {"x-forwarded-for", "203.0.113.7"},
    {"forwarded", "for=203.0.113.7"},
    {"x-real-ip", "203.0.113.7"},
    {"cf-connecting-ip", "203.0.113.7"}
  ]

  describe "from_conn/1" do
    test "forwarded headers and client fields cannot replace transport identity" do
      conn =
        Enum.reduce(@forged_headers, build_conn(:post, "/", %{"ip" => "203.0.113.7"}), fn
          {name, value}, conn -> put_req_header(conn, name, value)
        end)

      assert {:ok, {10, 1, 2, 3}} = ClientIdentity.from_conn(%{conn | remote_ip: {10, 1, 2, 3}})
    end

    test "missing peer metadata fails closed" do
      assert {:error, :invalid_identity} =
               ClientIdentity.from_conn(%{build_conn() | remote_ip: nil})
    end
  end

  describe "endpoint socket metadata" do
    test "websocket and longpoll LiveView transports provide peer data" do
      assert {"/live", Phoenix.LiveView.Socket, opts} =
               List.keyfind(TipsWeb.Endpoint.__sockets__(), "/live", 0)

      for transport <- [:websocket, :longpoll] do
        connect_info = opts |> Keyword.fetch!(transport) |> Keyword.fetch!(:connect_info)
        assert :peer_data in connect_info, "#{transport} lacks :peer_data"
      end
    end
  end
end
