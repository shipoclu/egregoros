defmodule PleromaReduxWeb.MastodonAPI.MarkersControllerTest do
  use PleromaReduxWeb.ConnCase, async: true

  import Mox

  alias PleromaRedux.Users

  test "GET /api/v1/markers returns marker data", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    PleromaRedux.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn = get(conn, "/api/v1/markers", %{"timeline" => ["home"]})
    response = json_response(conn, 200)

    assert response == %{}
  end

  test "POST /api/v1/markers updates markers", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    PleromaRedux.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn =
      post(conn, "/api/v1/markers", %{
        "home" => %{"last_read_id" => "1"},
        "notifications" => %{"last_read_id" => "1"}
      })

    response = json_response(conn, 200)

    assert response == %{}
  end
end

