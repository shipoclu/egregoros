defmodule EgregorosWeb.MastodonAPI.TagsControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.Publish
  alias Egregoros.Users

  test "GET /api/v1/tags/:name returns tag information", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")
    assert {:ok, _} = Publish.post_note(user, "Hello #linux")

    conn = get(conn, "/api/v1/tags/linux")
    response = json_response(conn, 200)

    assert response["id"] == "linux"
    assert response["name"] == "linux"
    assert is_binary(response["url"])
    assert String.contains?(response["url"], "/tags/linux")
    assert is_list(response["history"])
    assert length(response["history"]) == 7

    assert Enum.any?(response["history"], fn entry ->
             entry["uses"] == "1" and entry["accounts"] == "1"
           end)
  end

  test "GET /api/v1/tags/:name returns zeros for an unused tag", %{conn: conn} do
    conn = get(conn, "/api/v1/tags/nope")
    response = json_response(conn, 200)

    assert response["name"] == "nope"
    assert length(response["history"]) == 7
    assert Enum.all?(response["history"], &(&1["uses"] == "0"))
  end

  test "GET /api/v1/tags/:name returns 404 for invalid tag name", %{conn: conn} do
    conn = get(conn, "/api/v1/tags/bad%20tag")
    assert response(conn, 404) == "Not Found"
  end
end
