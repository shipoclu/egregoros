defmodule EgregorosWeb.MiniAppRegistrationControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.Repo

  test "idempotently returns one public client without an anonymous secret race", %{conn: conn} do
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
    refute Map.has_key?(response, "client_secret")
    assert response["client_name"] == "Writer"
    assert response["redirect_uris"] == ["https://app.example/oauth/callback"]
    assert response["scope"] == "identify write"

    assert response["scope_authorization_max_age_seconds"] == %{
             "identify" => 31_536_000,
             "write" => 86_400
           }

    assert response["grant_types"] == ["authorization_code", "refresh_token"]
    assert response["response_types"] == ["code"]
    assert response["token_endpoint_auth_method"] == "none"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]

    replay_conn = post(recycle(conn), "/oauth/mini-app/register", params)
    replay = json_response(replay_conn, 200)

    assert replay == response
    refute replay_conn.resp_body =~ "client_secret"
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

  test "applies operator disable and deny policy before any remote fetch", %{conn: conn} do
    manifest_url = "https://app.example/.well-known/fediverse-miniapp.json"

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> false
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("operator policy must reject registration before remote fetch")
    end)

    disabled_conn = post(conn, "/oauth/mini-app/register", %{"manifest_url" => manifest_url})
    assert json_response(disabled_conn, 403)["error"] == "disabled"

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> ["app.example"]
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    denied_conn =
      disabled_conn
      |> recycle()
      |> post("/oauth/mini-app/register", %{"manifest_url" => manifest_url})

    assert json_response(denied_conn, 403)["error"] == "domain_denied"
  end

  test "reports immutable manifest conflicts without creating a second client", %{conn: conn} do
    enable_mini_apps()

    changed_manifest =
      manifest_json()
      |> Jason.decode!()
      |> put_in(["oauth", "scopes"], ["identify"])
      |> put_in(["oauth", "scopeAuthorizationMaxAgeSeconds"], %{
        "identify" => 31_536_000
      })
      |> Jason.encode!()

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 2, fn
      "https://app.example/.well-known/fediverse-miniapp.json", :manifest ->
        body = if Process.get(:registration_created), do: changed_manifest, else: manifest_json()
        Process.put(:registration_created, true)
        ok_response(body)
    end)

    params = %{
      "manifest_url" => "https://app.example/.well-known/fediverse-miniapp.json"
    }

    first_conn = post(conn, "/oauth/mini-app/register", params)
    assert json_response(first_conn, 201)["client_id"]

    conflict_conn = post(recycle(first_conn), "/oauth/mini-app/register", params)
    assert json_response(conflict_conn, 409)["error"] == "manifest_changed"
    assert Repo.aggregate(OAuthApplication, :count) == 1
  end

  defp manifest_json do
    Jason.encode!(%{
      "version" => "1",
      "name" => "Writer",
      "homeUrl" => "https://app.example/",
      "oauth" => %{
        "redirectUris" => ["https://app.example/oauth/callback"],
        "scopes" => ["identify", "write"],
        "scopeAuthorizationMaxAgeSeconds" => %{
          "identify" => 31_536_000,
          "write" => 86_400
        }
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
