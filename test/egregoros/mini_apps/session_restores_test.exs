defmodule Egregoros.MiniApps.SessionRestoresTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.MiniApps.SessionRestore
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
    {:ok, user} = Users.create_local_user("restore-user")

    %{application: application, user: user}
  end

  test "issues and atomically consumes a verifier-bound identity proof", context do
    insert_grant!(context.application, context.user, "identify write")
    verifier = random_value()
    challenge = challenge(verifier)

    assert {:ok, restore_code} =
             SessionRestores.issue(
               context.user,
               "https://app.example",
               context.application.client_id,
               challenge
             )

    restore = Repo.one!(SessionRestore)
    refute restore.code_digest == restore_code
    assert restore.code_digest == digest(restore_code)
    assert restore.restore_challenge == challenge
    assert restore.app_origin == "https://app.example"

    assert {:ok, claims} = SessionRestores.consume(restore_code, verifier)
    assert claims.issuer == EgregorosWeb.Endpoint.url()
    assert claims.sub == context.user.ap_id
    assert claims.acct == "#{context.user.nickname}@#{URI.parse(claims.issuer).host}"
    refute Map.has_key?(claims, :name)
    assert Repo.get!(SessionRestore, restore.id).consumed_at

    assert {:error, :invalid_restore} = SessionRestores.consume(restore_code, verifier)
  end

  test "does not consume a proof for the wrong verifier", context do
    insert_grant!(context.application, context.user, "identify")
    verifier = random_value()

    assert {:ok, restore_code} =
             SessionRestores.issue(
               context.user,
               "https://app.example",
               context.application.client_id,
               challenge(verifier)
             )

    assert {:error, :invalid_restore} = SessionRestores.consume(restore_code, random_value())
    refute Repo.one!(SessionRestore).consumed_at
    assert {:ok, _claims} = SessionRestores.consume(restore_code, verifier)
  end

  test "fails closed after expiry or OAuth revocation", context do
    token = insert_grant!(context.application, context.user, "identify write")
    verifier = random_value()

    assert {:ok, expired_code} =
             SessionRestores.issue(
               context.user,
               "https://app.example",
               context.application.client_id,
               challenge(verifier)
             )

    Repo.one!(SessionRestore)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :invalid_restore} = SessionRestores.consume(expired_code, verifier)

    assert {:ok, revoked_code} =
             SessionRestores.issue(
               context.user,
               "https://app.example",
               context.application.client_id,
               challenge(verifier)
             )

    token
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:error, :invalid_restore} = SessionRestores.consume(revoked_code, verifier)
  end

  test "adds public presentation claims only for an active profile grant", context do
    {:ok, user} =
      Users.update_profile(context.user, %{
        name: "Restore User",
        avatar_url: "https://cdn.example/restore.png"
      })

    insert_grant!(context.application, user, "identify profile")
    verifier = random_value()

    assert {:ok, restore_code} =
             SessionRestores.issue(
               user,
               "https://app.example",
               context.application.client_id,
               challenge(verifier)
             )

    assert {:ok, claims} = SessionRestores.consume(restore_code, verifier)
    assert claims.preferred_username == user.nickname
    assert claims.name == "Restore User"
    assert claims.profile == EgregorosWeb.Endpoint.url() <> "/@#{user.nickname}"
    assert claims.picture == "https://cdn.example/restore.png"
  end

  test "returns interaction required for mismatched clients, origins, and missing grants",
       context do
    challenge = challenge(random_value())

    assert {:error, :interaction_required} =
             SessionRestores.issue(
               context.user,
               "https://app.example",
               context.application.client_id,
               challenge
             )

    insert_grant!(context.application, context.user, "identify")

    assert {:error, :interaction_required} =
             SessionRestores.issue(
               context.user,
               "https://other.example",
               context.application.client_id,
               challenge
             )

    assert {:error, :interaction_required} =
             SessionRestores.issue(
               context.user,
               "https://app.example",
               "wrong-client-12345",
               challenge
             )
  end

  test "fails closed for malformed issue and consume inputs", context do
    assert {:error, :interaction_required} =
             SessionRestores.issue(
               nil,
               "https://app.example",
               context.application.client_id,
               challenge(random_value())
             )

    assert {:error, :interaction_required} =
             SessionRestores.issue(
               context.user,
               "https://app.example/path",
               context.application.client_id,
               "short"
             )

    assert {:error, :invalid_restore} = SessionRestores.consume(nil, random_value())
    assert {:error, :invalid_restore} = SessionRestores.consume("not valid!", "short")
  end

  defp insert_grant!(application, user, scopes) do
    now = DateTime.utc_now()

    %Token{}
    |> Token.changeset(%{
      token_digest: digest(random_value()),
      refresh_token_digest: digest(random_value()),
      family_id: Ecto.UUID.generate(),
      scopes: scopes,
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
        scopes: ["identify", "profile", "write"],
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
