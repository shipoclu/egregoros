defmodule EgregorosWeb.OAuthControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.OAuth
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.Repo
  alias Egregoros.Users

  test "POST /oauth/token exchanges a code for a bearer token", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Husky",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read"
      })

    {:ok, auth_code} =
      OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read")

    conn =
      post(conn, "/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => auth_code.code,
        "client_id" => app.client_id,
        "client_secret" => app.client_secret,
        "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
      })

    response = json_response(conn, 200)
    assert response["token_type"] == "Bearer"
    assert response["scope"] == "read"
    assert is_binary(response["access_token"])
    assert is_binary(response["refresh_token"])
    assert response["expires_in"] in 3_590..3_600
  end

  test "POST /oauth/token exchanges a refresh_token for a new bearer token", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Husky",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read"
      })

    {:ok, auth_code} =
      OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read")

    conn =
      post(conn, "/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => auth_code.code,
        "client_id" => app.client_id,
        "client_secret" => app.client_secret,
        "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
      })

    first = json_response(conn, 200)
    assert is_binary(first["access_token"])
    assert is_binary(first["refresh_token"])

    conn =
      post(build_conn(), "/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => first["refresh_token"],
        "client_id" => app.client_id,
        "client_secret" => app.client_secret
      })

    second = json_response(conn, 200)
    assert is_binary(second["access_token"])
    assert second["access_token"] != first["access_token"]
    assert is_binary(second["refresh_token"])
    assert second["refresh_token"] != first["refresh_token"]
  end

  test "POST /oauth/token issues an app token for client_credentials", %{conn: conn} do
    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Ivory for iOS",
        "redirect_uris" =>
          "com.tapbots.Ivory.23600:/request_token/39A4ABC7-48F1-4DBC-906A-4D2D249C3440",
        "scopes" => "read write follow push"
      })

    conn =
      post(conn, "/oauth/token", %{
        "grant_type" => "client_credentials",
        "client_id" => app.client_id,
        "client_secret" => app.client_secret,
        "redirect_uri" => List.first(app.redirect_uris),
        "scope" => "read write follow push"
      })

    response = json_response(conn, 200)
    assert response["token_type"] == "Bearer"
    assert response["scope"] == "read write follow push"
    assert is_binary(response["access_token"])
    assert is_binary(response["refresh_token"])
  end

  test "POST /oauth/revoke revokes an access token", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Husky",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read"
      })

    {:ok, auth_code} =
      OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read")

    conn =
      post(conn, "/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => auth_code.code,
        "client_id" => app.client_id,
        "client_secret" => app.client_secret,
        "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
      })

    token = json_response(conn, 200)["access_token"]
    assert OAuth.get_user_by_token(token)

    conn =
      post(build_conn(), "/oauth/revoke", %{
        "token" => token,
        "client_id" => app.client_id,
        "client_secret" => app.client_secret
      })

    assert response(conn, 200)
    refute OAuth.get_user_by_token(token)
  end

  test "GET /oauth/authorize redirects to login when not signed in", %{conn: conn} do
    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Husky",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read"
      })

    conn =
      get(conn, "/oauth/authorize", %{
        "client_id" => app.client_id,
        "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
        "response_type" => "code",
        "scope" => "read"
      })

    assert redirected_to(conn) =~ "/login"
  end

  test "GET /oauth/authorize renders consent when signed in", %{conn: conn} do
    {:ok, user} =
      Users.register_local_user(%{
        nickname: "alice",
        email: "alice@example.com",
        password: "very secure password"
      })

    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Husky",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> get("/oauth/authorize", %{
        "client_id" => app.client_id,
        "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
        "response_type" => "code",
        "scope" => "read"
      })

    html = html_response(conn, 200)
    assert html =~ "Authorize"
    assert html =~ "Husky"
    assert html =~ ~s(data-role="app-shell")
    assert html =~ ~s(data-role="nav-settings")
  end

  test "POST /oauth/authorize approves and redirects with code", %{conn: conn} do
    {:ok, user} =
      Users.register_local_user(%{
        nickname: "alice",
        email: "alice@example.com",
        password: "very secure password"
      })

    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Husky",
        "redirect_uris" => "https://client.example/cb",
        "scopes" => "read"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> post("/oauth/authorize", %{
        "oauth" => %{
          "client_id" => app.client_id,
          "redirect_uri" => "https://client.example/cb",
          "response_type" => "code",
          "scope" => "read"
        }
      })

    location = redirected_to(conn)
    assert String.starts_with?(location, "https://client.example/cb")
    assert location =~ "code="
  end

  test "mini-app consent identifies the origin and requires separate write confirmation", %{
    conn: conn
  } do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    {:ok, user} =
      Users.register_local_user(%{
        nickname: "miniapp-oauth-user",
        email: "miniapp-oauth@example.com",
        password: "very secure password"
      })

    manifest_json =
      Jason.encode!(%{
        "version" => "1",
        "name" => "Writer",
        "homeUrl" => "https://app.example/",
        "oauth" => %{
          "redirectUris" => ["https://app.example/oauth/callback"],
          "scopes" => ["read", "write"]
        },
        "capabilities" => ["compose_note"]
      })

    {:ok, manifest} =
      Manifest.decode(
        manifest_json,
        "https://app.example/.well-known/fediverse-miniapp.json"
      )

    {:ok, registration} = OAuthRegistrations.register(manifest)
    app = Repo.get!(Egregoros.OAuth.Application, registration.oauth_application_id)
    verifier = String.duplicate("v", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    oauth_params = %{
      "client_id" => app.client_id,
      "redirect_uri" => "https://app.example/oauth/callback",
      "response_type" => "code",
      "scope" => "read write",
      "state" => "state-1",
      "code_challenge" => challenge,
      "code_challenge_method" => "S256"
    }

    consent_conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> get("/oauth/authorize", oauth_params)

    document = consent_conn |> html_response(200) |> LazyHTML.from_document()

    assert get_resp_header(consent_conn, "cache-control") == ["no-store"]
    assert get_resp_header(consent_conn, "pragma") == ["no-cache"]
    assert get_resp_header(consent_conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(consent_conn, "cross-origin-opener-policy") == ["same-origin"]

    assert [csp] = get_resp_header(consent_conn, "content-security-policy")
    assert csp =~ "form-action 'self' https://app.example"
    refute csp =~ "https://app.example/oauth/callback"

    assert document |> LazyHTML.query("#oauth-mini-app-origin") |> LazyHTML.text() =~
             "app.example"

    assert document |> LazyHTML.query("#oauth-mini-app-capabilities") |> LazyHTML.text() =~
             "prefilled note draft"

    assert LazyHTML.query(document, "#oauth-write-confirmation[required]") |> LazyHTML.to_tree() !=
             []

    cancel_url =
      document
      |> LazyHTML.query("#oauth-cancel")
      |> LazyHTML.attribute("href")
      |> List.first()

    cancel_query = cancel_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert String.starts_with?(cancel_url, "https://app.example/oauth/callback?")
    assert cancel_query == %{"error" => "access_denied", "state" => "state-1"}

    rejected_conn =
      conn
      |> recycle()
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> post("/oauth/authorize", %{"oauth" => oauth_params})

    assert response(rejected_conn, 400) =~ "Invalid OAuth request"

    approved_conn =
      conn
      |> recycle()
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> post("/oauth/authorize", %{
        "oauth" => Map.put(oauth_params, "write_confirmed", "true")
      })

    assert redirected_to(approved_conn) =~ "https://app.example/oauth/callback"
  end
end
