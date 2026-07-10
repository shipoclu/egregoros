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

  test "create_application stores empty redirect_uris when given nil or an invalid value" do
    assert {:error, %Ecto.Changeset{}} =
             OAuth.create_application(%{"client_name" => "Husky", "redirect_uris" => nil})

    assert {:error, %Ecto.Changeset{}} =
             OAuth.create_application(%{"client_name" => "Husky", "redirect_uris" => 123})
  end

  test "create_application rejects unsafe redirect URI forms" do
    for redirect_uri <- [
          "http://example.com/callback",
          "https://user@example.com/callback",
          "https://example.com/callback#fragment",
          "javascript:alert(1)",
          "file:///tmp/token",
          "https://example.com/callback\nSet-Cookie: x=y"
        ] do
      assert {:error, %Ecto.Changeset{}} =
               OAuth.create_application(%{
                 "client_name" => "Unsafe",
                 "redirect_uris" => redirect_uri
               })
    end
  end

  test "create_application permits HTTPS, loopback, OOB, and reverse-domain native redirects" do
    for redirect_uri <- [
          "https://example.com/callback",
          "http://localhost:4000/callback",
          "http://127.0.0.1:49152/callback",
          "urn:ietf:wg:oauth:2.0:oob",
          "com.example.native:/oauth/callback"
        ] do
      assert {:ok, _app} =
               OAuth.create_application(%{
                 "client_name" => "Safe",
                 "redirect_uris" => redirect_uri
               })
    end
  end

  test "public native redirects require S256 PKCE" do
    user = create_user!()
    app = create_app!(%{"redirect_uris" => "com.example.native:/oauth/callback"})

    assert {:error, :pkce_required} =
             OAuth.create_authorization_code(
               app,
               user,
               "com.example.native:/oauth/callback",
               "read"
             )

    verifier = String.duplicate("v", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert {:ok, _code} =
             OAuth.create_authorization_code(
               app,
               user,
               "com.example.native:/oauth/callback",
               "read",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )
  end

  test "get_application_by_client_id returns nil for nil ids" do
    assert OAuth.get_application_by_client_id(nil) == nil
  end

  test "get_authorization_code returns nil for nil inputs" do
    assert OAuth.get_authorization_code(nil) == nil
  end

  test "redirect_uri_allowed? returns false for non-matching inputs" do
    app = create_app!(%{"redirect_uris" => ["https://example.com/callback"]})

    assert OAuth.redirect_uri_allowed?(app, "https://example.com/callback") == true
    assert OAuth.redirect_uri_allowed?(app, "https://example.com/other") == false
    assert OAuth.redirect_uri_allowed?(app, nil) == false
    assert OAuth.redirect_uri_allowed?(nil, "https://example.com/callback") == false
  end

  test "get_user_by_token and get_token return nil for nil tokens" do
    assert OAuth.get_user_by_token(nil) == nil
    assert OAuth.get_token(nil) == nil
  end

  test "exchange_code_for_token returns unsupported_grant_type for unknown grants" do
    assert OAuth.exchange_code_for_token(%{"grant_type" => "password"}) ==
             {:error, :unsupported_grant_type}
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
    assert %DateTime{} = token.expires_at
    assert DateTime.diff(token.expires_at, DateTime.utc_now(), :second) in 3_590..3_600
    assert OAuth.get_user_by_token(token.token).id == user.id
    assert OAuth.get_authorization_code(auth_code.code) == nil
  end

  test "authorization code exchange verifies an S256 PKCE challenge" do
    user = create_user!()
    app = create_app!()
    verifier = String.duplicate("a", 43)

    challenge =
      :crypto.hash(:sha256, verifier)
      |> Base.url_encode64(padding: false)

    assert {:ok, auth_code} =
             OAuth.create_authorization_code(
               app,
               user,
               "urn:ietf:wg:oauth:2.0:oob",
               "read",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    params = %{
      "grant_type" => "authorization_code",
      "code" => auth_code.code,
      "client_id" => app.client_id,
      "client_secret" => app.client_secret,
      "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
    }

    assert {:error, :invalid_grant} =
             OAuth.exchange_code_for_token(Map.put(params, "code_verifier", "wrong"))

    assert {:ok, _token} =
             OAuth.exchange_code_for_token(Map.put(params, "code_verifier", verifier))
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

  test "authorization code exchange fails when the authorization code cannot be found" do
    app = create_app!()

    assert {:error, :invalid_grant} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => "missing",
               "client_id" => app.client_id,
               "client_secret" => app.client_secret,
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

  test "reusing a consumed refresh token revokes its token family" do
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

    refresh_params = %{
      "grant_type" => "refresh_token",
      "refresh_token" => token.refresh_token,
      "client_id" => app.client_id,
      "client_secret" => app.client_secret
    }

    assert {:ok, successor} = OAuth.exchange_code_for_token(refresh_params)
    assert {:error, :invalid_grant} = OAuth.exchange_code_for_token(refresh_params)
    assert OAuth.get_token(successor.token) == nil
  end

  test "concurrent refresh replay mints at most one successor and revokes the family" do
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

    refresh_params = %{
      "grant_type" => "refresh_token",
      "refresh_token" => token.refresh_token,
      "client_id" => app.client_id,
      "client_secret" => app.client_secret
    }

    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.Supervisor.async_nolink(supervisor, fn ->
          receive do
            :go -> OAuth.exchange_code_for_token(refresh_params)
          end
        end)
      end

    Enum.each(tasks, fn task ->
      Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, task.pid)
      Mox.allow(Egregoros.Config.Mock, parent, task.pid)
      send(task.pid, :go)
    end)

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, %Token{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_grant})) == 1

    {:ok, successor} = Enum.find(results, &match?({:ok, %Token{}}, &1))
    assert OAuth.get_token(successor.token) == nil
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

  test "revoke_token rejects unknown applications" do
    assert OAuth.revoke_token(%{
             "token" => "token",
             "client_id" => "missing",
             "client_secret" => "x"
           }) ==
             {:error, :invalid_client}
  end

  test "revoke_token rejects missing params" do
    assert OAuth.revoke_token(%{"token" => "x"}) == {:error, :invalid_request}
  end
end
