defmodule TipsWeb.LiveAcceptance do
  @moduledoc "Allows browser tests to share their SQL sandbox with connected LiveViews."

  import Phoenix.LiveView, only: [get_connect_info: 2]

  def on_mount(:default, _params, _session, socket) do
    Phoenix.Ecto.SQL.Sandbox.allow(
      get_connect_info(socket, :user_agent),
      Ecto.Adapters.SQL.Sandbox
    )

    {:cont, socket}
  end
end
