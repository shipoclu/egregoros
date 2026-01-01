defmodule EgregorosWeb.MastodonAPI.ConversationsControllerTest do
  use EgregorosWeb.ConnCase, async: true

  import Mox

  alias Egregoros.Users

  test "GET /api/v1/conversations returns []", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    assert conn |> get("/api/v1/conversations") |> json_response(200) == []
  end
end
