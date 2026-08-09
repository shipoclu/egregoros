defmodule EgregorosWeb.MiniAppSessionRestoreControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.MiniApps.SessionRestores
  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.OAuth.Token
  alias Egregoros.Repo
  alias Egregoros.Users

  setup do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    {:ok, user} = Users.create_local_user("restore-controller-user")
    insert_grant!(application, user)

    %{application: application, user: user}
  end

  test "consumes a proof without CORS and returns only narrow identity claims", context do
    verifier = random_value()

    {:ok, code} =
      SessionRestores.issue(
        context.user,
        "https://app.example",
        context.application.client_id,
        challenge(verifier)
      )

    conn =
      context.conn
      |> put_req_header("origin", "https://app.example")
      |> post("/api/v1/mini-apps/session-restores/consume", %{
        "restoreCode" => code,
        "restoreVerifier" => verifier
      })

    assert %{
             "issuer" => issuer,
             "sub" => sub,
             "acct" => acct
           } = json_response(conn, 200)

    assert issuer == EgregorosWeb.Endpoint.url()
    assert sub == context.user.ap_id
    assert acct =~ context.user.nickname
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "access-control-allow-origin") == []

    replay =
      post(recycle(conn), "/api/v1/mini-apps/session-restores/consume", %{
        "restoreCode" => code,
        "restoreVerifier" => verifier
      })

    assert json_response(replay, 400) == %{"error" => "invalid_restore"}
  end

  test "uses the same failure for malformed and verifier-mismatched proofs", context do
    verifier = random_value()

    {:ok, code} =
      SessionRestores.issue(
        context.user,
        "https://app.example",
        context.application.client_id,
        challenge(verifier)
      )

    wrong =
      post(context.conn, "/api/v1/mini-apps/session-restores/consume", %{
        "restoreCode" => code,
        "restoreVerifier" => random_value()
      })

    malformed =
      post(recycle(wrong), "/api/v1/mini-apps/session-restores/consume", %{
        "restoreCode" => "not valid!",
        "restoreVerifier" => "short"
      })

    assert json_response(wrong, 400) == %{"error" => "invalid_restore"}
    assert json_response(malformed, 400) == %{"error" => "invalid_restore"}
  end

  test "rejects extra and missing consume fields without browser-readable CORS", %{conn: conn} do
    response =
      conn
      |> put_req_header("origin", "https://app.example")
      |> post("/api/v1/mini-apps/session-restores/consume", %{
        "restoreCode" => random_value(),
        "unexpected" => true
      })

    assert json_response(response, 400) == %{"error" => "invalid_restore"}
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "access-control-allow-origin") == []
  end

  defp insert_grant!(application, user) do
    now = DateTime.utc_now()

    %Token{}
    |> Token.changeset(%{
      token_digest: digest(random_value()),
      refresh_token_digest: digest(random_value()),
      family_id: Ecto.UUID.generate(),
      scopes: "identify write",
      user_id: user.id,
      application_id: application.id,
      expires_at: DateTime.add(now, 3_600, :second),
      refresh_expires_at: DateTime.add(now, 86_400, :second)
    })
    |> Repo.insert!()
  end

  defp manifest_fixture do
    %Manifest{
      version: "1",
      name: "Restore app",
      origin: "https://app.example",
      home_url: "https://app.example/",
      oauth: %{
        redirect_uris: ["https://app.example/oauth/callback"],
        scopes: ["identify", "write"],
        scope_authorization_max_age_seconds: %{}
      },
      wallet: nil,
      activity_pub: nil,
      capabilities: [],
      cache_ttl_seconds: 600
    }
  end

  defp random_value, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp challenge(value), do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
