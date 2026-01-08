defmodule EgregorosWeb.HealthControllerTest do
  use EgregorosWeb.ConnCase, async: true

  test "GET /health returns ok json", %{conn: conn} do
    conn = get(conn, "/health")
    body = json_response(conn, 200)

    assert body["status"] == "ok"
    assert body["db"] == "ok"
    assert is_binary(body["version"])
  end
end

