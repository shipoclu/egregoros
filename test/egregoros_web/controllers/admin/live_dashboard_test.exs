defmodule EgregorosWeb.Admin.LiveDashboardTest do
  use EgregorosWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias Egregoros.Users

  test "GET /admin/dashboard redirects guests to login", %{conn: conn} do
    conn = get(conn, "/admin/dashboard")
    assert redirected_to(conn) == "/login"
  end

  test "GET /admin/dashboard rejects non-admins", %{conn: conn} do
    {:ok, user} = Users.create_local_user("bob")
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    conn = get(conn, "/admin/dashboard")
    assert response(conn, 403) =~ "Forbidden"
  end

  test "GET /admin/dashboard renders for admins", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, user} = Users.set_admin(user, true)
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    conn = get(conn, "/admin/dashboard")
    assert redirected_to(conn) == "/admin/dashboard/home"

    conn = get(recycle(conn), "/admin/dashboard/home")
    assert html_response(conn, 200)
  end

  test "GET /admin/dashboard/os_mon renders for admins", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, user} = Users.set_admin(user, true)
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    _log =
      capture_log(fn ->
        conn = get(conn, "/admin/dashboard/os_mon")
        assert html_response(conn, 200)
      end)
  end

  test "GET /admin/dashboard/ecto_stats renders for admins", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, user} = Users.set_admin(user, true)
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    conn = get(conn, "/admin/dashboard/ecto_stats")
    html = html_response(conn, 200)
    assert html =~ "Egregoros.Repo"
  end
end
