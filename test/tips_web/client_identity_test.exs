defmodule TipsWeb.ClientIdentityTest do
  use TipsWeb.ConnCase, async: true

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
