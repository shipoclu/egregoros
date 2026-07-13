defmodule EgregorosWeb.MiniAppIdentityControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.OAuth
  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.Repo
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint

  setup do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    {:ok, user} = Users.create_local_user("identify-only-mini-app-user")
    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    token = oauth_token(application, user)

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
      |> get("/api/v1/mini-apps/identity")

    assert json_response(conn, 200) == %{
             "id" => user.ap_id,
             "username" => user.nickname,
             "acct" => "#{user.nickname}@#{URI.parse(Endpoint.url()).host}",
             "display_name" => user.name || user.nickname,
             "url" => Endpoint.url() <> "/@#{user.nickname}"
           }

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end

  test "identify cannot use broad read or write API routes", %{
    conn: conn,
    token: token,
    user: user
  } do
    expect(Egregoros.Auth.Mock, :current_user, 2, fn _conn -> {:ok, user} end)

    expect(Egregoros.AuthZ.Mock, :authorize, fn _conn, ["read"] ->
      {:error, :insufficient_scope}
    end)

    expect(Egregoros.AuthZ.Mock, :authorize, fn _conn, ["write"] ->
      {:error, :insufficient_scope}
    end)

    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    assert response(get(conn, "/api/v1/accounts/verify_credentials"), 403)

    assert response(
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> post("/api/v1/statuses", %{"status" => "must not publish"}),
             403
           )
  end

  defp oauth_token(application, user) do
    verifier = String.duplicate("v", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert {:ok, code} =
             OAuth.create_authorization_code(
               application,
               user,
               "https://app.example/oauth/callback",
               "identify",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:ok, token} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => code.code,
               "client_id" => application.client_id,
               "redirect_uri" => "https://app.example/oauth/callback",
               "code_verifier" => verifier
             })

    token.token
  end

  defp manifest_fixture do
    attrs = %{
      "version" => "1",
      "name" => "Identity linker",
      "homeUrl" => "https://app.example/",
      "oauth" => %{
        "redirectUris" => ["https://app.example/oauth/callback"],
        "scopes" => ["identify"]
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
