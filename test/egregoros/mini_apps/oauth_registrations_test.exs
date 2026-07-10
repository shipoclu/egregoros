defmodule Egregoros.MiniApps.OAuthRegistrationsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.OAuth
  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.OAuth.Token
  alias Egregoros.Repo
  alias Egregoros.Users

  setup do
    enable_mini_apps()
    :ok
  end

  test "creates exactly one issuer client for repeated registration of an app" do
    manifest = manifest_fixture()

    assert {:ok, first} = OAuthRegistrations.register(manifest)
    assert {:ok, second} = OAuthRegistrations.register(manifest)

    assert first.id == second.id
    assert first.app_origin == "https://app.example"
    assert first.redirect_uris == ["https://app.example/oauth/callback"]
    assert first.scopes == ["read", "write"]
    assert first.capabilities == ["compose_note"]
    assert first.oauth_application_id == second.oauth_application_id
    assert Repo.aggregate(OAuthApplication, :count) == 1

    application = Repo.get!(OAuthApplication, first.oauth_application_id)
    assert application.name == "Writer"
    assert application.website == "https://app.example/"
    assert application.redirect_uris == ["https://app.example/oauth/callback"]
    assert application.scopes == "read write"
  end

  test "rejects immutable OAuth or capability changes without creating another client" do
    assert {:ok, registration} = OAuthRegistrations.register(manifest_fixture())

    changed = manifest_fixture(scopes: ["read"])
    assert {:error, :manifest_changed} = OAuthRegistrations.register(changed)

    changed = manifest_fixture(capabilities: [])
    assert {:error, :manifest_changed} = OAuthRegistrations.register(changed)

    assert Repo.aggregate(OAuthApplication, :count) == 1
    assert OAuthRegistrations.get_by_origin("https://app.example").id == registration.id
  end

  test "requires OAuth metadata and current operator permission" do
    manifest = %{manifest_fixture() | oauth: nil, capabilities: []}
    assert {:error, :oauth_not_declared} = OAuthRegistrations.register(manifest)

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> ["app.example"]
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    assert {:error, :domain_denied} = OAuthRegistrations.register(manifest_fixture())
    assert Repo.aggregate(OAuthApplication, :count) == 0
  end

  test "enforces exact scopes, S256 PKCE, and current policy throughout token use" do
    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    {:ok, user} = Users.create_local_user("mini-app-oauth-user")
    redirect_uri = "https://app.example/oauth/callback"
    verifier = String.duplicate("v", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert OAuthRegistrations.capability_allowed?("https://app.example", "compose_note")
    refute OAuthRegistrations.capability_allowed?("https://app.example", "wallet")
    refute OAuthRegistrations.active_user_grant?("https://app.example", user.id)

    assert {:error, :pkce_required} =
             OAuth.create_authorization_code(
               application,
               user,
               redirect_uri,
               "read write"
             )

    assert {:error, :invalid_scope} =
             OAuth.create_authorization_code(application, user, redirect_uri, "read",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:ok, code} =
             OAuth.create_authorization_code(application, user, redirect_uri, "read write",
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

    assert %Token{} = OAuth.get_token(token.token)
    assert OAuthRegistrations.active_user_grant?("https://app.example", user.id)

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> ["app.example"]
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    assert OAuth.get_token(token.token) == nil
    assert Repo.get!(Token, token.id).revoked_at
    refute OAuthRegistrations.capability_allowed?("https://app.example", "compose_note")
    refute OAuthRegistrations.active_user_grant?("https://app.example", user.id)
  end

  defp manifest_fixture(overrides \\ []) do
    scopes = Keyword.get(overrides, :scopes, ["read", "write"])
    capabilities = Keyword.get(overrides, :capabilities, ["compose_note"])

    json =
      Jason.encode!(%{
        "version" => "1",
        "name" => "Writer",
        "homeUrl" => "https://app.example/",
        "oauth" => %{
          "redirectUris" => ["https://app.example/oauth/callback"],
          "scopes" => scopes
        },
        "capabilities" => capabilities
      })

    assert {:ok, manifest} =
             Manifest.decode(
               json,
               "https://app.example/.well-known/fediverse-miniapp.json"
             )

    manifest
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
