defmodule TipsWeb.HealthController do
  use TipsWeb, :controller

  def show(conn, _params) do
    probe = Application.get_env(:tips, :health_check, &Tips.Health.check/0)
    conn = put_resp_header(conn, "cache-control", "no-store")

    case probe.() do
      :ok -> json(conn, %{status: "ok"})
      :error -> conn |> put_status(:service_unavailable) |> json(%{status: "error"})
    end
  end
end
