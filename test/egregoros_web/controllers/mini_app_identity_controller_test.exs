defmodule EgregorosWeb.MiniAppIdentityControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.Auth.BearerToken
  alias Egregoros.AuthZ.OAuthScopes
  alias Egregoros.OAuth
  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.Repo
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint

  setup do
    stub(Egregoros.Auth.Mock, :current_user, &BearerToken.current_user/1)
    stub(Egregoros.AuthZ.Mock, :authorize, &OAuthScopes.authorize/2)

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    {:ok, user} = Users.create_local_user("identify-only-mini-app-user")
    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    token = oauth_token(application, user, "identify")

    %{user: user, token: token}
  end

  test "returns only the minimal authenticated Fediverse identity", %{
    conn: conn,
    user: user,
    token: token
  } do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/accounts/verify_credentials")

    assert json_response(conn, 200) == %{
             "sub" => user.ap_id,
             "acct" => "#{user.nickname}@#{URI.parse(Endpoint.url()).host}"
           }

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
  end

  test "profile adds only public presentation fields", %{conn: conn, user: user} do
    {:ok, user} =
      Users.update_profile(user, %{
        name: "Alice Example",
        avatar_url: "https://cdn.example/alice.png"
      })

    {:ok, application} =
      OAuth.create_application(%{
        "client_name" => "Public profile client",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "identify profile"
      })

    token =
      oauth_token(application, user, "identify profile", "urn:ietf:wg:oauth:2.0:oob")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/accounts/verify_credentials")

    assert json_response(conn, 200) == %{
             "sub" => user.ap_id,
             "acct" => "#{user.nickname}@#{URI.parse(Endpoint.url()).host}",
             "preferred_username" => user.nickname,
             "name" => user.name || user.nickname,
             "profile" => Endpoint.url() <> "/@#{user.nickname}",
             "picture" => "https://cdn.example/alice.png"
           }
  end

  test "profile alone cannot be authorized", %{user: user} do
    {:ok, application} =
      OAuth.create_application(%{
        "client_name" => "Profile-only client",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "profile"
      })

    assert {:error, :invalid_scope} =
             OAuth.create_authorization_code(
               application,
               user,
               "urn:ietf:wg:oauth:2.0:oob",
               "profile"
             )
  end

  test "identify can verify identity but cannot use write API routes", %{
    conn: conn,
    token: token,
    user: user
  } do
    expect(Egregoros.Auth.Mock, :current_user, 2, fn _conn -> {:ok, user} end)

    expect(Egregoros.AuthZ.Mock, :authorize, 3, fn _conn, scopes ->
      if scopes == ["identify"], do: :ok, else: {:error, :insufficient_scope}
    end)

    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    user_ap_id = user.ap_id

    assert %{"sub" => ^user_ap_id} =
             conn
             |> get("/api/v1/accounts/verify_credentials")
             |> json_response(200)

    assert response(
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> post("/api/v1/statuses", %{"status" => "must not publish"}),
             403
           )
  end

  defp oauth_token(
         application,
         user,
         scopes,
         redirect_uri \\ "https://app.example/oauth/callback"
       ) do
    verifier = String.duplicate("v", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert {:ok, code} =
             OAuth.create_authorization_code(
               application,
               user,
               redirect_uri,
               scopes,
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    token_params = %{
      "grant_type" => "authorization_code",
      "code" => code.code,
      "client_id" => application.client_id,
      "redirect_uri" => redirect_uri,
      "code_verifier" => verifier
    }

    token_params =
      if application.client_type == :confidential,
        do: Map.put(token_params, "client_secret", application.client_secret),
        else: token_params

    assert {:ok, token} = OAuth.exchange_code_for_token(token_params)

    token.token
  end

  defp manifest_fixture(scopes \\ ["identify"]) do
    attrs = %{
      "version" => "1",
      "name" => "Identity linker",
      "homeUrl" => "https://app.example/",
      "oauth" => %{
        "redirectUris" => ["https://app.example/oauth/callback"],
        "scopes" => scopes
      },
      "capabilities" => []
    }

    assert {:ok, manifest} =
             Manifest.decode(
               Jason.encode!(attrs),
               "https://app.example/.well-known/fediverse-miniapp.json"
             )

    manifest
  end
end
