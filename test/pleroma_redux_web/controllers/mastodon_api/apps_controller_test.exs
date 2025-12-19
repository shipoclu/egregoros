defmodule PleromaReduxWeb.MastodonAPI.AppsControllerTest do
  use PleromaReduxWeb.ConnCase, async: true

  alias PleromaRedux.OAuth

  test "POST /api/v1/apps registers an oauth application", %{conn: conn} do
    conn =
      post(conn, "/api/v1/apps", %{
        "client_name" => "Husky",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read write follow",
        "website" => "https://example.com"
      })

    response = json_response(conn, 200)

    assert response["name"] == "Husky"
    assert response["redirect_uri"] == "urn:ietf:wg:oauth:2.0:oob"
    assert is_binary(response["client_id"])
    assert is_binary(response["client_secret"])

    assert %{} = OAuth.get_application_by_client_id(response["client_id"])
  end
end

