defmodule EgregorosWeb.MiniAppDeveloperLiveTest do
  use EgregorosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Egregoros.Users

  test "requires login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/developer/mini-apps")
  end

  test "requires the developer preference", %{conn: conn} do
    {:ok, user} = Users.create_local_user("developer-disabled")
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    assert {:error, {:redirect, %{to: "/settings"}}} = live(conn, "/developer/mini-apps")
  end

  test "renders for a user who enabled developer mode", %{conn: conn} do
    {:ok, user} = Users.create_local_user("developer-enabled")
    {:ok, user} = Users.update_profile(user, %{"developer_mode" => true})
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, "/developer/mini-apps")

    assert has_element?(view, "[data-role='mini-app-developer']")
    assert has_element?(view, "[data-role='nav-developer'][aria-current='page']")
  end
end
