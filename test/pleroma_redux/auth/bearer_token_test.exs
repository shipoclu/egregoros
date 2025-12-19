defmodule PleromaRedux.Auth.BearerTokenTest do
  use PleromaRedux.DataCase, async: true

  import Plug.Conn
  import Plug.Test

  alias PleromaRedux.Auth.BearerToken
  alias PleromaRedux.OAuth
  alias PleromaRedux.Users

  test "current_user returns unauthorized when token is missing" do
    conn = conn(:get, "/api/v1/accounts/verify_credentials")
    assert {:error, :unauthorized} = BearerToken.current_user(conn)
  end

  test "current_user resolves a user from a bearer token" do
    {:ok, user} = Users.create_local_user("alice")

    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Husky",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read"
      })

    {:ok, auth_code} =
      OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read")

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

    assert {:ok, resolved} = BearerToken.current_user(conn)
    assert resolved.id == user.id
  end
end
