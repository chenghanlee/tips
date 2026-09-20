defmodule TipsWeb.HealthControllerTest do
  use TipsWeb.ConnCase, async: false

  test "GET /healthz returns uncached ok when the Repo answers", %{conn: conn} do
    conn = get(conn, "/healthz")

    assert json_response(conn, 200) == %{"status" => "ok"}
    assert conn.resp_body == ~s({"status":"ok"})
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "GET /healthz returns uncached error when the probe fails", %{conn: conn} do
    previous = Application.fetch_env(:tips, :health_check)
    Application.put_env(:tips, :health_check, fn -> :error end)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tips, :health_check, value)
        :error -> Application.delete_env(:tips, :health_check)
      end
    end)

    conn = get(conn, "/healthz")

    assert json_response(conn, 503) == %{"status" => "error"}
    assert conn.resp_body == ~s({"status":"error"})
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
