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

  test "GET /healthz serves JSON to browser Accept headers", %{conn: conn} do
    conn = conn |> put_req_header("accept", "text/html,application/xhtml+xml") |> get("/healthz")

    assert json_response(conn, 200) == %{"status" => "ok"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  @tag capture_log: true
  test "GET /healthz bounds the database outage probe", %{conn: conn} do
    repo =
      start_supervised!(
        {Tips.Repo,
         name: Tips.UnavailableHealthRepo,
         hostname: "127.0.0.1",
         port: 1,
         pool: DBConnection.ConnectionPool,
         pool_size: 1}
      )

    previous = Tips.Repo.get_dynamic_repo()

    try do
      Tips.Repo.put_dynamic_repo(repo)
      started = System.monotonic_time(:millisecond)
      conn = get(conn, "/healthz")
      elapsed = System.monotonic_time(:millisecond) - started

      assert json_response(conn, 503) == %{"status" => "error"}
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      # Allow scheduling overhead, but reject waiting beyond the probe deadline.
      assert elapsed < 2_000
    after
      Tips.Repo.put_dynamic_repo(previous)
    end
  end
end
