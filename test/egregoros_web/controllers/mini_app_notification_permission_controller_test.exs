defmodule EgregorosWeb.MiniAppNotificationPermissionControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.NotificationConsents
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.OAuth
  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.Repo
  alias Egregoros.Users

  setup do
    enable_mini_apps()
    {:ok, user} = Users.create_local_user("mini-app-notification-api-user")
    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    token = oauth_token(application, user)
    %{user: user, token: token}
  end

  test "returns the canonical recipient and immutable app actor only for current consent", %{
    conn: conn,
    user: user,
    token: token
  } do
    assert {:ok, _consent} =
             NotificationConsents.decide(user.id, "https://app.example", :granted)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/mini-apps/notification-permission?recipientActor=https://evil.example/u/x")

    assert json_response(conn, 200) == %{
             "state" => "granted",
             "recipientActor" => user.ap_id,
             "appActor" => "https://app.example/ap/actor"
           }

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end

  test "returns denied without recipient data when consent is absent or denied", %{
    conn: conn,
    user: user,
    token: token
  } do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/mini-apps/notification-permission")

    assert json_response(conn, 200) == %{"state" => "denied"}

    assert {:ok, _consent} =
             NotificationConsents.decide(user.id, "https://app.example", :denied)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/mini-apps/notification-permission")

    assert json_response(conn, 200) == %{"state" => "denied"}
  end

  test "rejects missing tokens and OAuth clients that are not registered mini apps", %{
    conn: conn,
    user: user
  } do
    assert json_response(get(conn, "/api/v1/mini-apps/notification-permission"), 401) == %{
             "error" => "unauthorized"
           }

    {:ok, application} =
      OAuth.create_application(%{
        "client_name" => "Ordinary client",
        "redirect_uris" => ["https://client.example/callback"],
        "scopes" => "read"
      })

    token = oauth_token(application, user, "https://client.example/callback")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/mini-apps/notification-permission")

    assert json_response(conn, 403) == %{"error" => "not_mini_app"}
  end

  test "fails closed after OAuth revocation or an operator domain denial", %{
    conn: conn,
    user: user,
    token: token
  } do
    assert {:ok, _consent} =
             NotificationConsents.decide(user.id, "https://app.example", :granted)

    assert :ok = OAuthRegistrations.revoke_user_grant("https://app.example", user.id)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/mini-apps/notification-permission")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}

    fresh_token = oauth_token(Repo.get_by!(OAuthApplication, client_id: client_id()), user)

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> ["app.example"]
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{fresh_token}")
      |> get("/api/v1/mini-apps/notification-permission")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  defp oauth_token(application, user, redirect_uri \\ "https://app.example/oauth/callback") do
    verifier = String.duplicate("v", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert {:ok, code} =
             OAuth.create_authorization_code(
               application,
               user,
               redirect_uri,
               "read",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:ok, token} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => code.code,
               "client_id" => application.client_id,
               "client_secret" => application.client_secret,
               "redirect_uri" => redirect_uri,
               "code_verifier" => verifier
             })

    token.token
  end

  defp manifest_fixture do
    attrs = %{
      "version" => "1",
      "name" => "Alerts",
      "homeUrl" => "https://app.example/",
      "oauth" => %{
        "redirectUris" => ["https://app.example/oauth/callback"],
        "scopes" => ["read"]
      },
      "activityPub" => %{
        "actorUrl" => "https://app.example/ap/actor",
        "publicNotes" => true,
        "transactionalMentions" => true
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

  defp client_id do
    OAuthRegistrations.get_by_origin("https://app.example")
    |> then(&Repo.get!(OAuthApplication, &1.oauth_application_id))
    |> Map.fetch!(:client_id)
  end

  defp enable_mini_apps do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)
  end
end
