defmodule EgregorosWeb.ObanDashboardTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.Users

  test "GET /admin/oban redirects guests to login", %{conn: conn} do
    conn = get(conn, "/admin/oban")
    assert redirected_to(conn) == "/login"
  end

  test "GET /admin/oban rejects non-admins", %{conn: conn} do
    {:ok, user} = Users.create_local_user("bob")
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    conn = get(conn, "/admin/oban")
    assert response(conn, 403) =~ "Forbidden"
  end

  test "GET /admin/oban is routed to the Oban dashboard LiveView" do
    assert %{
             mfa: {Oban.Web.DashboardLive, :__live__, 0},
             pipe_through: [:browser, :admin]
           } =
             Phoenix.Router.route_info(EgregorosWeb.Router, "GET", "/admin/oban", "localhost")
  end
end
