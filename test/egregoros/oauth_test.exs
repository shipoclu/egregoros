defmodule Egregoros.OAuthTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.OAuth
  alias Egregoros.OAuth.Token
  alias Egregoros.Repo
  alias Egregoros.Users

  defp unique_nickname(prefix) do
    prefix <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp create_user! do
    {:ok, user} = Users.create_local_user(unique_nickname("alice"))
    user
  end

  defp create_app!(attrs \\ %{}) do
    {:ok, app} =
      OAuth.create_application(
        Map.merge(
          %{
            "client_name" => "Husky",
            "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
            "scopes" => "read write follow"
          },
          attrs
        )
      )

    app
  end

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

  test "create_application accepts redirect_uris as a list and de-duplicates them" do
    app =
      create_app!(%{
        "redirect_uris" => [
          "urn:ietf:wg:oauth:2.0:oob",
          " urn:ietf:wg:oauth:2.0:oob ",
          "",
          nil,
          123
        ]
      })

    assert app.redirect_uris == ["urn:ietf:wg:oauth:2.0:oob"]
  end

  test "authorization codes require a registered redirect uri" do
    user = create_user!()
    app = create_app!(%{"scopes" => "read"})

    assert {:error, :invalid_redirect_uri} =
             OAuth.create_authorization_code(app, user, "https://evil.example/cb", "read")
  end

  test "authorization codes require requested scopes to be a subset of app scopes" do
    user = create_user!()
    app = create_app!(%{"scopes" => "read"})

    assert {:error, :invalid_scope} =
             OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read write")
  end

  test "authorization code can be exchanged for an access token" do
    user = create_user!()
    app = create_app!()

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
    assert OAuth.get_authorization_code(auth_code.code) == nil
  end

  test "authorization code exchange fails for invalid client id" do
    assert {:error, :invalid_client} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => "nope",
               "client_id" => "missing",
               "client_secret" => "missing",
               "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
             })
  end

  test "authorization code exchange fails for incorrect client secret" do
    user = create_user!()
    app = create_app!()

    assert {:ok, auth_code} =
             OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read")

    assert {:error, :invalid_grant} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => auth_code.code,
               "client_id" => app.client_id,
               "client_secret" => "wrong",
               "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
             })
  end

  test "authorization code exchange fails for expired codes" do
    user = create_user!()
    app = create_app!()

    assert {:ok, auth_code} =
             OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read")

    {:ok, _} =
      auth_code
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Repo.update()

    assert {:error, :invalid_grant} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => auth_code.code,
               "client_id" => app.client_id,
               "client_secret" => app.client_secret,
               "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
             })
  end

  test "access and refresh tokens are not stored in plaintext" do
    user = create_user!()
    app = create_app!()

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

  test "refresh grant issues a new token and revokes the old one" do
    user = create_user!()
    app = create_app!()

    assert {:ok, auth_code} =
             OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read write")

    assert {:ok, token} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => auth_code.code,
               "client_id" => app.client_id,
               "client_secret" => app.client_secret,
               "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
             })

    assert {:ok, refreshed} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "refresh_token",
               "refresh_token" => token.refresh_token,
               "client_id" => app.client_id,
               "client_secret" => app.client_secret
             })

    assert refreshed.token != token.token
    assert refreshed.refresh_token != token.refresh_token
    assert OAuth.get_user_by_token(refreshed.token).id == user.id

    old = OAuth.get_token(token.token)
    assert old == nil
  end

  test "refresh grant can narrow scopes but not widen them" do
    user = create_user!()
    app = create_app!(%{"scopes" => "read write"})

    assert {:ok, auth_code} =
             OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read write")

    assert {:ok, token} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => auth_code.code,
               "client_id" => app.client_id,
               "client_secret" => app.client_secret,
               "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
             })

    assert {:ok, narrowed} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "refresh_token",
               "refresh_token" => token.refresh_token,
               "client_id" => app.client_id,
               "client_secret" => app.client_secret,
               "scope" => "read"
             })

    assert narrowed.scopes == "read"

    assert {:error, :invalid_scope} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "refresh_token",
               "refresh_token" => narrowed.refresh_token,
               "client_id" => app.client_id,
               "client_secret" => app.client_secret,
               "scope" => "read write"
             })
  end

  test "refresh grant rejects tokens with expired refresh windows" do
    user = create_user!()
    app = create_app!()

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

    stored = Repo.get_by!(Token, token_digest: OAuth.get_token(token.token).token_digest)

    {:ok, _} =
      stored
      |> Ecto.Changeset.change(refresh_expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Repo.update()

    assert {:error, :invalid_grant} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "refresh_token",
               "refresh_token" => token.refresh_token,
               "client_id" => app.client_id,
               "client_secret" => app.client_secret
             })
  end

  test "client credentials grant issues an app token without a user" do
    app = create_app!(%{"scopes" => "read write"})

    assert {:ok, token} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "client_credentials",
               "client_id" => app.client_id,
               "client_secret" => app.client_secret
             })

    assert token.scopes == "read write"
    assert OAuth.get_user_by_token(token.token) == nil
  end

  test "client credentials grant rejects invalid scopes" do
    app = create_app!(%{"scopes" => "read"})

    assert {:error, :invalid_scope} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "client_credentials",
               "client_id" => app.client_id,
               "client_secret" => app.client_secret,
               "scope" => "write"
             })
  end

  test "client credentials grant rejects disallowed redirect_uri params" do
    app = create_app!(%{"redirect_uris" => "https://good.example/cb"})

    assert {:error, :invalid_redirect_uri} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "client_credentials",
               "client_id" => app.client_id,
               "client_secret" => app.client_secret,
               "redirect_uri" => "https://evil.example/cb"
             })
  end

  test "revoke_token revokes both access and refresh tokens" do
    user = create_user!()
    app = create_app!()

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

    assert :ok =
             OAuth.revoke_token(%{
               "token" => token.token,
               "client_id" => app.client_id,
               "client_secret" => app.client_secret
             })

    assert OAuth.get_token(token.token) == nil

    assert :ok =
             OAuth.revoke_token(%{
               "token" => token.refresh_token,
               "client_id" => app.client_id,
               "client_secret" => app.client_secret
             })

    assert OAuth.exchange_code_for_token(%{
             "grant_type" => "refresh_token",
             "refresh_token" => token.refresh_token,
             "client_id" => app.client_id,
             "client_secret" => app.client_secret
           }) == {:error, :invalid_grant}
  end

  test "revoke_token rejects missing params" do
    assert OAuth.revoke_token(%{"token" => "x"}) == {:error, :invalid_request}
  end
end
