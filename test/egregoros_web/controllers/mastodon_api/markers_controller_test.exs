defmodule EgregorosWeb.MastodonAPI.MarkersControllerTest do
  use EgregorosWeb.ConnCase, async: true

  import Mox

  alias Egregoros.Users

  test "GET /api/v1/markers returns marker data", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, 2, fn _conn -> {:ok, user} end)

    _ =
      post(conn, "/api/v1/markers", %{
        "home" => %{"last_read_id" => "1"}
      })

    conn = get(conn, "/api/v1/markers", %{"timeline" => ["home"]})
    response = json_response(conn, 200)

    assert response["home"]["last_read_id"] == "1"
    assert response["home"]["version"] == 1
    assert is_binary(response["home"]["updated_at"])
  end

  test "POST /api/v1/markers updates markers", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn =
      post(conn, "/api/v1/markers", %{
        "home" => %{"last_read_id" => "1"},
        "notifications" => %{"last_read_id" => "1"}
      })

    response = json_response(conn, 200)

    assert response["home"]["last_read_id"] == "1"
    assert response["notifications"]["last_read_id"] == "1"
  end
end
