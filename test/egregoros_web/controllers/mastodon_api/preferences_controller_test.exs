defmodule EgregorosWeb.MastodonAPI.PreferencesControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.Users

  test "GET /api/v1/preferences returns a map", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn = get(conn, "/api/v1/preferences")
    response = json_response(conn, 200)

    assert is_map(response)
  end
end
