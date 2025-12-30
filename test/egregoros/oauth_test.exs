defmodule Egregoros.OAuthTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.OAuth
  alias Egregoros.Users

  test "create_application stores redirect uris and secrets" do
    assert {:ok, app} =
             OAuth.create_application(%{
               "client_name" => "Husky",
               "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
               "scopes" => "read write follow",
               "website" => "https://example.com"
             })

    assert app.name == "Husky"
    assert app.redirect_uris == ["urn:ietf:wg:oauth:2.0:oob"]
    assert is_binary(app.client_id) and byte_size(app.client_id) > 10
    assert is_binary(app.client_secret) and byte_size(app.client_secret) > 10
  end

  test "authorization codes require a registered redirect uri" do
    {:ok, user} = Users.create_local_user("alice")

    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Husky",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read"
      })

    assert {:error, :invalid_redirect_uri} =
             OAuth.create_authorization_code(app, user, "https://evil.example/cb", "read")
  end

  test "authorization code can be exchanged for an access token" do
    {:ok, user} = Users.create_local_user("alice")

    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Husky",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read write follow"
      })

    assert {:ok, auth_code} =
             OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read")

    assert {:ok, token} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => auth_code.code,
               "client_id" => app.client_id,
               "client_secret" => app.client_secret,
               "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
             })

    assert is_binary(token.token)
    assert OAuth.get_user_by_token(token.token).id == user.id
  end

  test "access and refresh tokens are not stored in plaintext" do
    {:ok, user} = Users.create_local_user("alice")

    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Husky",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read write follow"
      })

    assert {:ok, auth_code} =
             OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read")

    assert {:ok, token} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => auth_code.code,
               "client_id" => app.client_id,
               "client_secret" => app.client_secret,
               "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
             })

    assert is_binary(token.token)
    assert is_binary(token.refresh_token)

    stored = OAuth.get_token(token.token)
    assert stored.token != token.token
    assert stored.refresh_token != token.refresh_token
  end
end
