defmodule Egregoros.OAuthTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.OAuth
  alias Egregoros.Users

  test "create_application normalizes redirect uris from strings, lists, and nil" do
    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "App",
        "redirect_uris" => "https://example.com/callback\nhttps://example.com/callback2\nhttps://example.com/callback"
      })

    assert app.redirect_uris == [
             "https://example.com/callback",
             "https://example.com/callback2"
           ]

    {:ok, app} =
      OAuth.create_application(%{
        client_name: "App 2",
        redirect_uris: ["https://example.com/callback", " ", "https://example.com/callback2"]
      })

    assert app.redirect_uris == [
             "https://example.com/callback",
             "https://example.com/callback2"
           ]

    {:ok, app} =
      OAuth.create_application(%{
        client_name: "App 3",
        redirect_uris: nil
      })

    assert app.redirect_uris == []

    {:ok, app} =
      OAuth.create_application(%{
        client_name: "App 4",
        redirect_uris: 123
      })

    assert app.redirect_uris == []
  end

  test "get_application_by_client_id returns nil for nil ids" do
    assert OAuth.get_application_by_client_id(nil) == nil
  end

  test "redirect_uri_allowed? returns false for non-matching inputs" do
    {:ok, app} =
      OAuth.create_application(%{
        client_name: "App",
        redirect_uris: ["https://example.com/callback"]
      })

    assert OAuth.redirect_uri_allowed?(app, "https://example.com/callback") == true
    assert OAuth.redirect_uri_allowed?(app, "https://example.com/other") == false
    assert OAuth.redirect_uri_allowed?(app, nil) == false
    assert OAuth.redirect_uri_allowed?(nil, "https://example.com/callback") == false
  end

  test "create_authorization_code rejects invalid redirect uris and scopes" do
    unique = Ecto.UUID.generate()
    {:ok, user} = Users.create_local_user("alice-#{unique}")

    {:ok, app} =
      OAuth.create_application(%{
        client_name: "App",
        redirect_uris: ["https://example.com/callback"],
        scopes: "read write follow"
      })

    assert {:error, :invalid_redirect_uri} =
             OAuth.create_authorization_code(app, user, "https://evil.example/callback", "read")

    assert {:error, :invalid_scope} =
             OAuth.create_authorization_code(app, user, "https://example.com/callback", "admin")
  end

  test "get_authorization_code returns nil for nil inputs" do
    assert OAuth.get_authorization_code(nil) == nil
  end

  test "exchange_code_for_token returns unsupported_grant_type for unknown grants" do
    assert OAuth.exchange_code_for_token(%{"grant_type" => "password"}) ==
             {:error, :unsupported_grant_type}
  end

  test "exchange_code_for_token returns invalid_client when the application cannot be found" do
    assert OAuth.exchange_code_for_token(%{
             "grant_type" => "authorization_code",
             "code" => "code",
             "client_id" => "missing",
             "client_secret" => "missing",
             "redirect_uri" => "https://example.com/callback"
           }) == {:error, :invalid_client}
  end

  test "exchange_code_for_token returns invalid_grant when the authorization code cannot be found" do
    unique = Ecto.UUID.generate()
    {:ok, user} = Users.create_local_user("alice-#{unique}")

    {:ok, app} =
      OAuth.create_application(%{
        client_name: "App",
        redirect_uris: ["https://example.com/callback"],
        scopes: "read"
      })

    assert OAuth.exchange_code_for_token(%{
             "grant_type" => "authorization_code",
             "code" => "missing",
             "client_id" => app.client_id,
             "client_secret" => app.client_secret,
             "redirect_uri" => "https://example.com/callback"
           }) == {:error, :invalid_grant}

    assert {:ok, _auth_code} =
             OAuth.create_authorization_code(app, user, "https://example.com/callback", "read")
  end

  test "get_user_by_token and get_token return nil for nil tokens" do
    assert OAuth.get_user_by_token(nil) == nil
    assert OAuth.get_token(nil) == nil
  end

  test "revoke_token returns invalid_client for unknown applications" do
    assert OAuth.revoke_token(%{"token" => "token", "client_id" => "missing", "client_secret" => "x"}) ==
             {:error, :invalid_client}
  end

  test "revoke_token returns invalid_request when required parameters are missing" do
    assert OAuth.revoke_token(%{}) == {:error, :invalid_request}
  end
end

