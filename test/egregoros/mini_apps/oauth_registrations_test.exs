defmodule Egregoros.MiniApps.OAuthRegistrationsTest do
  use Egregoros.DataCase, async: false

  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.NotificationConsents
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.MiniApps.Permissions
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
    assert Declarations.get_by_origin("https://app.example")

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

  test "lists and immediately revokes a user's app grant and token family" do
    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    {:ok, user} = Users.create_local_user("mini-app-oauth-revoke-user")
    verifier = String.duplicate("v", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert {:ok, code} =
             OAuth.create_authorization_code(
               application,
               user,
               "https://app.example/oauth/callback",
               "read write",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:ok, token} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => code.code,
               "client_id" => application.client_id,
               "client_secret" => application.client_secret,
               "redirect_uri" => "https://app.example/oauth/callback",
               "code_verifier" => verifier
             })

    assert [%{app_origin: "https://app.example", scopes: ["read", "write"]}] =
             OAuthRegistrations.list_user_grants(user.id)

    Permissions.subscribe(user.id)
    assert :ok = OAuthRegistrations.revoke_user_grant("https://app.example", user.id)
    assert_receive {:mini_app_permission_revoked, "https://app.example", :oauth}
    assert OAuth.get_token(token.token) == nil
    assert OAuth.get_token(token.refresh_token) == nil
    refute OAuthRegistrations.active_user_grant?("https://app.example", user.id)
    assert OAuthRegistrations.list_user_grants(user.id) == []
    assert OAuthRegistrations.list_user_grants(nil) == []
    assert :ok = OAuthRegistrations.revoke_user_grant("https://missing.example", user.id)
    assert :ok = OAuthRegistrations.revoke_user_grant(nil, nil)
  end

  test "OAuth revocation waits for an in-flight notification delivery boundary" do
    assert {:ok, _registration} = OAuthRegistrations.register(manifest_fixture())
    assert {:ok, user} = Users.create_local_user("mini-app-oauth-revoke-lock-user")

    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    origin = "https://app.example"

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

        try do
          Repo.transaction(fn ->
            NotificationConsents.lock_delivery(user.id, origin)
            send(parent, {:delivery_lock_held, self()})

            receive do
              :release_delivery -> :released
            end
          end)
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Repo)
        end
      end)

    assert_receive {:delivery_lock_held, holder_pid}
    Permissions.subscribe(user.id)

    revoker =
      Task.Supervisor.async_nolink(supervisor, fn ->
        receive do
          :revoke ->
            [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:revoker_backend, backend_pid})
            result = OAuthRegistrations.revoke_user_grant(origin, user.id)
            send(parent, {:revocation_finished, result})
            result
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), revoker.pid)
    send(revoker.pid, :revoke)
    assert_receive {:revoker_backend, backend_pid}

    observer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

        try do
          wait_for_blocked_advisory_lock(backend_pid, System.monotonic_time(:millisecond) + 2_000)
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Repo)
        end
      end)

    assert :ok = Task.await(observer, 3_000)
    refute_receive {:revocation_finished, _result}
    refute_receive {:mini_app_permission_revoked, ^origin, :oauth}

    send(holder_pid, :release_delivery)
    assert_receive {:revocation_finished, :ok}
    assert_receive {:mini_app_permission_revoked, ^origin, :oauth}
    assert {:ok, :released} = Task.await(holder, 3_000)
    assert :ok = Task.await(revoker, 3_000)
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

  defp wait_for_blocked_advisory_lock(backend_pid, deadline) do
    [[waiting?]] =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_locks
          WHERE pid = $1 AND locktype = 'advisory' AND granted = false
        )
        """,
        [backend_pid]
      ).rows

    cond do
      waiting? ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        wait_for_blocked_advisory_lock(backend_pid, deadline)

      true ->
        {:error, :lock_not_observed}
    end
  end
end
