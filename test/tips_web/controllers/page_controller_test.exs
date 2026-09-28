defmodule TipsWeb.PageControllerTest do
  use TipsWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Find and share practical AI techniques"
  end
end
