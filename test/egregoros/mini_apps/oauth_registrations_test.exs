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
    runtime_policy_keys =
      ~w(mini_apps_enabled mini_apps_domain_allowlist mini_apps_domain_denylist)a

    previous_runtime_policy =
      Map.new(runtime_policy_keys, &{&1, Application.fetch_env(:egregoros, &1)})

    on_exit(fn ->
      Enum.each(previous_runtime_policy, fn
        {key, {:ok, value}} -> Application.put_env(:egregoros, key, value)
        {key, :error} -> Application.delete_env(:egregoros, key)
      end)
    end)

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
    assert first.scopes == ["identify", "write"]
    assert first.capabilities == ["compose_note"]
    assert first.oauth_application_id == second.oauth_application_id
    assert Repo.aggregate(OAuthApplication, :count) == 1
    assert Declarations.get_by_origin("https://app.example")

    application = Repo.get!(OAuthApplication, first.oauth_application_id)
    assert application.name == "Writer"
    assert application.website == "https://app.example/"
    assert application.redirect_uris == ["https://app.example/oauth/callback"]
    assert application.scopes == "identify write"
    assert application.client_type == :public_mini_app
  end

  test "rejects immutable OAuth or capability changes without creating another client" do
    assert {:ok, registration} = OAuthRegistrations.register(manifest_fixture())

    changed = manifest_fixture(scopes: ["identify"])
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

  test "fails closed for malformed boundary values and unregistered public applications" do
    assert {:error, :invalid_manifest} = OAuthRegistrations.register(%{})
    assert {:error, :invalid_manifest} = OAuthRegistrations.register(nil)
    assert {:error, :invalid_manifest} = OAuthRegistrations.register_with_status(%{})

    refute OAuthRegistrations.application_allowed?(nil)
    refute OAuthRegistrations.registration_allowed?(nil, nil)
    refute OAuthRegistrations.capability_allowed?(nil, nil)
    refute OAuthRegistrations.active_user_grant?(nil, nil)

    assert {:error, :invalid_request} =
             OAuthRegistrations.validate_authorization(nil, nil, nil, nil)

    assert {:ok, confidential} =
             OAuth.create_application(%{
               "client_name" => "Boundary test",
               "redirect_uris" => ["https://client.example/callback"],
               "scopes" => "read"
             })

    unregistered_public = %{confidential | client_type: :public_mini_app}
    refute OAuthRegistrations.application_allowed?(unregistered_public)

    assert {:error, :invalid_client} =
             OAuthRegistrations.validate_authorization(
               unregistered_public,
               "https://client.example/callback",
               "read",
               code_challenge: String.duplicate("c", 43),
               code_challenge_method: "S256"
             )

    assert {:error, :invalid_client} =
             OAuthRegistrations.validate_token_scopes(unregistered_public, "read")
  end

  test "public clients reject stale registration metadata and malformed authorization requests" do
    invalid_origin = %{manifest_fixture() | origin: "relative-origin"}
    assert {:error, :invalid_origin} = OAuthRegistrations.register(invalid_origin)

    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    challenge = String.duplicate("c", 43)
    redirect_uri = "https://app.example/oauth/callback"

    stale_application = %{application | redirect_uris: ["https://app.example/stale-callback"]}
    refute OAuthRegistrations.application_allowed?(stale_application)

    assert {:error, :invalid_client} =
             OAuthRegistrations.validate_authorization(
               stale_application,
               redirect_uri,
               "identify write",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:error, :invalid_redirect_uri} =
             OAuthRegistrations.validate_authorization(
               application,
               "https://app.example/not-registered",
               "identify write",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:error, :invalid_scope} =
             OAuthRegistrations.validate_authorization(
               application,
               redirect_uri,
               "read",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:error, :pkce_required} =
             OAuthRegistrations.validate_authorization(
               application,
               redirect_uri,
               "identify write",
               code_challenge: challenge
             )

    assert {:error, :pkce_required} =
             OAuthRegistrations.validate_authorization(
               application,
               redirect_uri,
               "identify write",
               code_challenge_method: "S256"
             )

    assert :ok = OAuthRegistrations.validate_token_scopes(application, "write identify")

    assert {:error, :invalid_scope} =
             OAuthRegistrations.validate_token_scopes(application, "read")
  end

  test "public token endpoints reject malformed credentials, replay, and stale tokens" do
    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    {:ok, user} = Users.create_local_user("mini-app-public-boundary-user")
    verifier = String.duplicate("b", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    redirect_uri = "https://app.example/oauth/callback"

    assert {:ok, code} =
             OAuth.create_authorization_code(
               application,
               user,
               redirect_uri,
               "identify write",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:error, :invalid_client} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => code.code,
               "client_id" => "unknown-client",
               "redirect_uri" => redirect_uri,
               "code_verifier" => verifier
             })

    for invalid_verifier <- [nil, "short", String.duplicate("x", 43)] do
      params = %{
        "grant_type" => "authorization_code",
        "code" => code.code,
        "client_id" => application.client_id,
        "redirect_uri" => redirect_uri
      }

      params =
        if is_binary(invalid_verifier),
          do: Map.put(params, "code_verifier", invalid_verifier),
          else: params

      assert {:error, :invalid_grant} = OAuth.exchange_code_for_token(params)
    end

    assert {:ok, token} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => code.code,
               "client_id" => application.client_id,
               "redirect_uri" => redirect_uri,
               "code_verifier" => verifier
             })

    assert {:error, :invalid_grant} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => code.code,
               "client_id" => application.client_id,
               "redirect_uri" => redirect_uri,
               "code_verifier" => verifier
             })

    assert {:error, :invalid_client} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "refresh_token",
               "refresh_token" => token.refresh_token,
               "client_id" => "unknown-client"
             })

    assert {:error, :invalid_client} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "refresh_token",
               "refresh_token" => token.refresh_token,
               "client_id" => application.client_id,
               "client_secret" => application.client_secret
             })

    assert {:error, :invalid_grant} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "refresh_token",
               "refresh_token" => "unknown-refresh-token",
               "client_id" => application.client_id
             })

    assert {:error, :invalid_scope} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "refresh_token",
               "refresh_token" => token.refresh_token,
               "client_id" => application.client_id,
               "scope" => "read"
             })

    Token
    |> Repo.get!(token.id)
    |> Ecto.Changeset.change(refresh_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :invalid_grant} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "refresh_token",
               "refresh_token" => token.refresh_token,
               "client_id" => application.client_id
             })

    assert :ok =
             OAuth.revoke_token(%{
               "token" => "unknown-token",
               "client_id" => application.client_id
             })

    assert {:error, :invalid_client} =
             OAuth.revoke_token(%{
               "token" => token.token,
               "client_id" => "unknown-client"
             })

    assert {:error, :invalid_request} = OAuth.revoke_token(%{})
    assert {:error, :unsupported_grant_type} = OAuth.exchange_code_for_token(%{})
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
               "identify write"
             )

    assert {:error, :invalid_scope} =
             OAuth.create_authorization_code(application, user, redirect_uri, "read",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:ok, code} =
             OAuth.create_authorization_code(application, user, redirect_uri, "identify write",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:ok, token} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => code.code,
               "client_id" => application.client_id,
               "redirect_uri" => redirect_uri,
               "code_verifier" => verifier
             })

    assert {:error, :invalid_client} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => "not-a-code",
               "client_id" => application.client_id,
               "client_secret" => application.client_secret,
               "redirect_uri" => redirect_uri,
               "code_verifier" => verifier
             })

    assert {:error, :unauthorized_client} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "client_credentials",
               "client_id" => application.client_id,
               "client_secret" => application.client_secret
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
               "identify write",
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

    assert {:ok, refreshed} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "refresh_token",
               "refresh_token" => token.refresh_token,
               "client_id" => application.client_id
             })

    assert [%{app_origin: "https://app.example", scopes: ["identify", "write"]}] =
             OAuthRegistrations.list_user_grants(user.id)

    Permissions.subscribe(user.id)
    assert :ok = OAuthRegistrations.revoke_user_grant("https://app.example", user.id)
    assert_receive {:mini_app_permission_revoked, "https://app.example", :oauth}
    assert OAuth.get_token(token.token) == nil
    assert OAuth.get_token(token.refresh_token) == nil
    assert OAuth.get_token(refreshed.token) == nil
    refute OAuthRegistrations.active_user_grant?("https://app.example", user.id)
    assert OAuthRegistrations.list_user_grants(user.id) == []
    assert OAuthRegistrations.list_user_grants(nil) == []
    assert :ok = OAuthRegistrations.revoke_user_grant("https://missing.example", user.id)
    assert :ok = OAuthRegistrations.revoke_user_grant(nil, nil)
  end

  test "public mini-app clients revoke by token possession and never by an internal secret" do
    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    {:ok, user} = Users.create_local_user("mini-app-public-revoke-user")
    verifier = String.duplicate("v", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert {:ok, code} =
             OAuth.create_authorization_code(
               application,
               user,
               "https://app.example/oauth/callback",
               "identify write",
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

    assert {:error, :invalid_client} =
             OAuth.revoke_token(%{
               "token" => token.token,
               "client_id" => application.client_id,
               "client_secret" => application.client_secret
             })

    assert %Token{} = OAuth.get_token(token.token)

    assert :ok =
             OAuth.revoke_token(%{
               "token" => token.refresh_token,
               "client_id" => application.client_id
             })

    assert OAuth.get_token(token.token) == nil
    assert OAuth.get_token(token.refresh_token) == nil
  end

  test "revoking a consumed public refresh token invalidates its entire token family" do
    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    {:ok, user} = Users.create_local_user("mini-app-public-family-revoke-user")
    verifier = String.duplicate("f", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert {:ok, code} =
             OAuth.create_authorization_code(
               application,
               user,
               "https://app.example/oauth/callback",
               "identify write",
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

    assert {:ok, successor} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "refresh_token",
               "refresh_token" => token.refresh_token,
               "client_id" => application.client_id
             })

    assert %Token{} = OAuth.get_token(successor.token)

    assert :ok =
             OAuth.revoke_token(%{
               "token" => token.refresh_token,
               "client_id" => application.client_id
             })

    assert OAuth.get_token(successor.token) == nil

    assert {:error, :invalid_grant} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "refresh_token",
               "refresh_token" => successor.refresh_token,
               "client_id" => application.client_id
             })
  end

  test "public client identity fails closed after its registration row is orphaned" do
    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    {:ok, user} = Users.create_local_user("mini-app-orphaned-public-client-user")
    verifier = String.duplicate("o", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert {:ok, token_code} =
             OAuth.create_authorization_code(
               application,
               user,
               "https://app.example/oauth/callback",
               "identify write",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:ok, token} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => token_code.code,
               "client_id" => application.client_id,
               "redirect_uri" => "https://app.example/oauth/callback",
               "code_verifier" => verifier
             })

    assert {:ok, orphaned_code} =
             OAuth.create_authorization_code(
               application,
               user,
               "https://app.example/oauth/callback",
               "identify write",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    Repo.delete!(registration)

    assert OAuth.get_token(token.token) == nil
    assert OAuthRegistrations.public_client?(application)

    assert {:error, :invalid_client} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => orphaned_code.code,
               "client_id" => application.client_id,
               "redirect_uri" => "https://app.example/oauth/callback",
               "code_verifier" => verifier
             })

    assert {:error, :invalid_client} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "refresh_token",
               "refresh_token" => token.refresh_token,
               "client_id" => application.client_id
             })

    assert {:error, :unauthorized_client} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "client_credentials",
               "client_id" => application.client_id,
               "client_secret" => application.client_secret
             })

    assert {:error, :invalid_client} =
             OAuth.revoke_token(%{
               "token" => token.token,
               "client_id" => application.client_id
             })
  end

  test "public authorization-code exchange rechecks policy after the grant lock" do
    set_runtime_mini_apps_policy([])
    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    {:ok, user} = Users.create_local_user("mini-app-code-revoke-race-user")
    verifier = String.duplicate("c", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    origin = "https://app.example"

    assert {:ok, code} =
             OAuth.create_authorization_code(
               application,
               user,
               "https://app.example/oauth/callback",
               "identify write",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    holder = hold_grant_lock(supervisor, parent, user.id, origin)

    assert_receive {:grant_lock_held, holder_pid}, 1_000

    exchanger =
      Task.Supervisor.async_nolink(supervisor, fn ->
        receive do
          :exchange ->
            Egregoros.Config.put_impl(Egregoros.Config.Stub)
            [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:exchange_backend, backend_pid})

            OAuth.exchange_code_for_token(%{
              "grant_type" => "authorization_code",
              "code" => code.code,
              "client_id" => application.client_id,
              "redirect_uri" => "https://app.example/oauth/callback",
              "code_verifier" => verifier
            })
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), exchanger.pid)
    send(exchanger.pid, :exchange)
    assert_receive {:exchange_backend, backend_pid}
    assert :ok = observe_blocked_advisory_lock(supervisor, backend_pid)

    set_runtime_mini_apps_policy(["app.example"])
    deny_mini_apps(["app.example"])
    send(holder_pid, :release)
    assert {:ok, :released} = Task.await(holder, 3_000)
    assert {:error, :invalid_client} = Task.await(exchanger, 3_000)
    refute OAuthRegistrations.active_user_grant?(origin, user.id)
  end

  test "public refresh rotation rechecks policy after the grant lock" do
    set_runtime_mini_apps_policy([])
    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    {:ok, user} = Users.create_local_user("mini-app-refresh-revoke-race-user")
    origin = "https://app.example"
    token = insert_public_token!(application, user)

    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    holder = hold_grant_lock(supervisor, parent, user.id, origin)

    assert_receive {:grant_lock_held, holder_pid}, 1_000

    refresher =
      Task.Supervisor.async_nolink(supervisor, fn ->
        receive do
          :refresh ->
            Egregoros.Config.put_impl(Egregoros.Config.Stub)
            [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:refresh_backend, backend_pid})

            OAuth.exchange_code_for_token(%{
              "grant_type" => "refresh_token",
              "refresh_token" => token.refresh_token,
              "client_id" => application.client_id
            })
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), refresher.pid)
    send(refresher.pid, :refresh)
    assert_receive {:refresh_backend, backend_pid}
    assert :ok = observe_blocked_advisory_lock(supervisor, backend_pid)

    set_runtime_mini_apps_policy(["app.example"])
    deny_mini_apps(["app.example"])
    send(holder_pid, :release)
    assert {:ok, :released} = Task.await(holder, 3_000)
    assert {:error, :invalid_client} = Task.await(refresher, 3_000)
    assert Repo.get!(Token, token.id).consumed_at == nil
    refute OAuthRegistrations.active_user_grant?(origin, user.id)
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

  defp hold_grant_lock(supervisor, parent, user_id, origin) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      try do
        Repo.transaction(fn ->
          NotificationConsents.lock_delivery(user_id, origin)
          send(parent, {:grant_lock_held, self()})

          receive do
            :release -> :released
          end
        end)
      after
        Ecto.Adapters.SQL.Sandbox.checkin(Repo)
      end
    end)
  end

  defp observe_blocked_advisory_lock(supervisor, backend_pid) do
    observer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

        try do
          wait_for_blocked_advisory_lock(backend_pid, System.monotonic_time(:millisecond) + 2_000)
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Repo)
        end
      end)

    Task.await(observer, 3_000)
  end

  defp insert_public_token!(application, user) do
    raw_token = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
    raw_refresh_token = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

    token =
      %Token{}
      |> Token.changeset(%{
        token_digest: token_digest(raw_token),
        refresh_token_digest: token_digest(raw_refresh_token),
        family_id: Ecto.UUID.generate(),
        scopes: "identify write",
        user_id: user.id,
        application_id: application.id,
        expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
        refresh_expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
      })
      |> Repo.insert!()

    %{token | token: raw_token, refresh_token: raw_refresh_token}
  end

  defp token_digest(token) do
    token
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp manifest_fixture(overrides \\ []) do
    scopes = Keyword.get(overrides, :scopes, ["identify", "write"])
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

  defp enable_mini_apps, do: deny_mini_apps([])

  defp set_runtime_mini_apps_policy(denylist) do
    Application.put_env(:egregoros, :mini_apps_enabled, true)
    Application.put_env(:egregoros, :mini_apps_domain_allowlist, [])
    Application.put_env(:egregoros, :mini_apps_domain_denylist, denylist)
  end

  defp deny_mini_apps(denylist) do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> denylist
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
