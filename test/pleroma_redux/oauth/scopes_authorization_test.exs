defmodule PleromaRedux.OAuth.ScopesAuthorizationTest do
  use PleromaRedux.DataCase, async: true

  alias PleromaRedux.OAuth
  alias PleromaRedux.Users

  test "create_authorization_code rejects scopes not allowed by application" do
    {:ok, user} = Users.create_local_user("alice")

    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Husky",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read"
      })

    assert {:error, :invalid_scope} =
             OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read write")
  end

  test "create_authorization_code allows scopes within application scope" do
    {:ok, user} = Users.create_local_user("alice")

    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Husky",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read write follow"
      })

    assert {:ok, _auth_code} =
             OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read write")
  end
end
