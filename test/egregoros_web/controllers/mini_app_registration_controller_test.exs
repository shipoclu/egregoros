defmodule EgregorosWeb.MiniAppRegistrationControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.Repo

  test "registers once, returns credentials once, and rejects anonymous replay", %{conn: conn} do
    enable_mini_apps()
    manifest = manifest_json()

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 2, fn
      "https://app.example/.well-known/fediverse-miniapp.json", :manifest ->
        ok_response(manifest)
    end)

    params = %{
      "manifest_url" => "https://app.example/.well-known/fediverse-miniapp.json"
    }

    conn = post(conn, "/oauth/mini-app/register", params)
    response = json_response(conn, 201)

    assert response["client_id"]
    assert response["client_secret"]
    assert response["client_name"] == "Writer"
    assert response["redirect_uris"] == ["https://app.example/oauth/callback"]
    assert response["scope"] == "read write"
    assert response["grant_types"] == ["authorization_code", "refresh_token"]
    assert response["response_types"] == ["code"]
    assert response["token_endpoint_auth_method"] == "client_secret_post"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]

    replay_conn = post(recycle(conn), "/oauth/mini-app/register", params)
    replay = json_response(replay_conn, 409)

    assert replay == %{
             "error" => "already_registered",
             "error_description" => "Reuse the existing registration for this issuer"
           }

    refute replay_conn.resp_body =~ response["client_secret"]
    assert Repo.aggregate(OAuthApplication, :count) == 1
  end

  test "rejects invalid manifest locations without fetching", %{conn: conn} do
    enable_mini_apps()

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("invalid manifest locations must not be fetched")
    end)

    conn =
      post(conn, "/oauth/mini-app/register", %{
        "manifest_url" => "https://app.example/not-the-manifest.json"
      })

    assert json_response(conn, 422)["error"] == "invalid_manifest_url"
  end

  test "requires an OAuth-enabled verified manifest", %{conn: conn} do
    enable_mini_apps()

    manifest =
      Jason.encode!(%{
        "version" => "1",
        "name" => "Reader",
        "homeUrl" => "https://app.example/",
        "capabilities" => []
      })

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/.well-known/fediverse-miniapp.json", :manifest ->
        ok_response(manifest)
    end)

    conn =
      post(conn, "/oauth/mini-app/register", %{
        "manifest_url" => "https://app.example/.well-known/fediverse-miniapp.json"
      })

    assert json_response(conn, 422)["error"] == "oauth_not_declared"
  end

  defp manifest_json do
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
  end

  defp enable_mini_apps do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)
  end

  defp ok_response(body) do
    {:ok, %{status: 200, body: body, headers: [{"content-type", "application/json"}]}}
  end
end
