defmodule EgregorosWeb.MastodonAPI.PushSubscriptionControllerTest do
  use EgregorosWeb.ConnCase, async: true

  import Mox

  alias Egregoros.Users

  test "GET /api/v1/push/subscription returns 404 when push is unsupported", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn = get(conn, "/api/v1/push/subscription")
    body = json_response(conn, 404)

    assert body["error"] == "push subscriptions are not supported"
  end

  test "POST /api/v1/push/subscription returns 404 when push is unsupported", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn = post(conn, "/api/v1/push/subscription", %{})
    body = json_response(conn, 404)

    assert body["error"] == "push subscriptions are not supported"
  end

  test "PUT /api/v1/push/subscription returns 404 when push is unsupported", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn = put(conn, "/api/v1/push/subscription", %{})
    body = json_response(conn, 404)

    assert body["error"] == "push subscriptions are not supported"
  end

  test "DELETE /api/v1/push/subscription returns 404 when push is unsupported", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn = delete(conn, "/api/v1/push/subscription")
    body = json_response(conn, 404)

    assert body["error"] == "push subscriptions are not supported"
  end
end
