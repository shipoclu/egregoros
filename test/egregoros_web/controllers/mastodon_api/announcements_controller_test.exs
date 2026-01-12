defmodule EgregorosWeb.MastodonAPI.AnnouncementsControllerTest do
  use EgregorosWeb.ConnCase, async: true

  test "GET /api/v1/announcements returns empty list", %{conn: conn} do
    conn = get(conn, "/api/v1/announcements")
    assert json_response(conn, 200) == []
  end

  test "POST /api/v1/announcements/:id/dismiss returns empty object", %{conn: conn} do
    conn = post(conn, "/api/v1/announcements/1/dismiss")
    assert json_response(conn, 200) == %{}
  end
end
