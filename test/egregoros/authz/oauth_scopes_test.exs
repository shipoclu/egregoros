defmodule Egregoros.AuthZ.OAuthScopesTest do
  use Egregoros.DataCase, async: true

  import Plug.Conn
  import Plug.Test

  alias Egregoros.AuthZ.OAuthScopes
  alias Egregoros.OAuth
  alias Egregoros.Users

  test "authorize returns unauthorized when token is missing" do
    conn = conn(:get, "/api/v1/accounts/verify_credentials")
    assert {:error, :unauthorized} = OAuthScopes.authorize(conn, ["read"])
  end

  test "authorize returns ok when token has required scopes" do
    {:ok, user} = Users.create_local_user("alice")

    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Husky",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read write follow"
      })

    {:ok, auth_code} =
      OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read follow")

    {:ok, token} =
      OAuth.exchange_code_for_token(%{
        "grant_type" => "authorization_code",
        "code" => auth_code.code,
        "client_id" => app.client_id,
        "client_secret" => app.client_secret,
        "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
      })

    conn =
      conn(:get, "/api/v1/accounts/verify_credentials")
      |> put_req_header("authorization", "Bearer " <> token.token)

    assert :ok == OAuthScopes.authorize(conn, ["read"])
    assert :ok == OAuthScopes.authorize(conn, ["follow"])
    assert {:error, :insufficient_scope} = OAuthScopes.authorize(conn, ["write", "admin"])
  end
end
