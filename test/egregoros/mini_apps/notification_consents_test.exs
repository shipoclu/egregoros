defmodule Egregoros.MiniApps.NotificationConsentsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.Declaration
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.NotificationConsents
  alias Egregoros.MiniApps.NotificationAudits
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.MiniApps.Permissions
  alias Egregoros.OAuth
  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.Repo
  alias Egregoros.Users

  setup do
    enable_mini_apps()
    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    activate_mini_app_actor!("https://app.example")
    {:ok, user} = Users.create_local_user("mini-app-notification-consent-user")
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    _token = grant_oauth(application, user)
    %{user: user}
  end

  test "records a decision bound to the immutable app actor", %{user: user} do
    assert NotificationConsents.state(user.id, "https://app.example") == :prompt
    refute NotificationConsents.granted?(user.id, "https://app.example")

    assert {:ok, denied} =
             NotificationConsents.decide(user.id, "https://app.example", :denied)

    assert denied.app_actor_url == "https://app.example/ap/actor"
    assert denied.decision == :denied
    assert NotificationConsents.state(user.id, "https://app.example") == :denied

    assert {:ok, granted} =
             NotificationConsents.decide(user.id, "https://app.example", :granted)

    assert granted.id == denied.id
    assert granted.decision == :granted
    assert NotificationConsents.granted?(user.id, "https://app.example")
    assert NotificationConsents.list_for_user(user.id) == [granted]

    assert Enum.map(NotificationAudits.list_for_user(user), & &1.event) == [
             :permission_granted,
             :permission_denied
           ]
  end

  test "requires a current transactional declaration and domain policy", %{user: user} do
    assert {:error, :notifications_not_declared} =
             NotificationConsents.decide(user.id, "https://other.example", :granted)

    deny_mini_apps(["app.example"])

    assert NotificationConsents.state(user.id, "https://app.example") == :prompt

    assert {:error, :notifications_not_declared} =
             NotificationConsents.decide(user.id, "https://app.example", :granted)
  end

  test "revocation is immediate and independently broadcast", %{user: user} do
    assert {:ok, _consent} =
             NotificationConsents.decide(user.id, "https://app.example", :granted)

    Permissions.subscribe(user.id)
    assert :ok = NotificationConsents.revoke(user.id, "https://app.example")
    assert_receive {:mini_app_permission_revoked, "https://app.example", :notifications}
    assert NotificationConsents.state(user.id, "https://app.example") == :prompt
    assert NotificationConsents.list_for_user(user.id) == []
    assert hd(NotificationAudits.list_for_user(user)).event == :permission_revoked
  end

  test "a stale approval serialized after OAuth revocation cannot restore consent", %{user: user} do
    result =
      Repo.transaction(fn ->
        assert :ok = OAuthRegistrations.revoke_user_grant("https://app.example", user.id)
        NotificationConsents.decide(user.id, "https://app.example", :granted)
      end)

    assert {:ok, {:error, :oauth_required}} = result
    refute NotificationConsents.granted?(user.id, "https://app.example")
  end

  test "a denial does not require an active OAuth grant", %{user: user} do
    assert :ok = OAuthRegistrations.revoke_user_grant("https://app.example", user.id)

    assert {:ok, consent} =
             NotificationConsents.decide(user.id, "https://app.example", :denied)

    assert consent.decision == :denied
    assert NotificationConsents.state(user.id, "https://app.example") == :denied
    assert hd(NotificationAudits.list_for_user(user)).event == :permission_denied
  end

  test "state refuses a consent whose immutable actor binding no longer matches", %{user: user} do
    assert {:ok, _consent} =
             NotificationConsents.decide(user.id, "https://app.example", :granted)

    from(declaration in Declaration,
      where: declaration.app_origin == "https://app.example"
    )
    |> Repo.update_all(set: [activity_pub_actor_url: "https://app.example/ap/new-actor"])

    assert NotificationConsents.state(user.id, "https://app.example") == :prompt
    refute NotificationConsents.granted?(user.id, "https://app.example")
  end

  test "an invalid actor binding fails without retaining consent or an audit", %{user: user} do
    invalid_actor_url = String.duplicate("a", 2_049)

    from(declaration in Declaration,
      where: declaration.app_origin == "https://app.example"
    )
    |> Repo.update_all(set: [activity_pub_actor_url: invalid_actor_url])

    assert {:error, changeset} =
             NotificationConsents.decide(user.id, "https://app.example", :granted)

    assert %{app_actor_url: [_too_long]} = errors_on(changeset)
    assert NotificationConsents.state(user.id, "https://app.example") == :prompt
    assert NotificationConsents.list_for_user(user.id) == []
    assert NotificationAudits.list_for_user(user) == []
  end

  test "grant approval checks OAuth only after acquiring the shared lock", %{user: user} do
    {result, queries} =
      capture_repo_queries(fn ->
        NotificationConsents.decide(user.id, "https://app.example", :granted)
      end)

    assert {:ok, _consent} = result

    lock_index =
      Enum.find_index(queries, &String.contains?(&1, "pg_advisory_xact_lock"))

    oauth_index =
      Enum.find_index(queries, &String.contains?(&1, ~s(FROM "oauth_tokens")))

    assert is_integer(lock_index)
    assert is_integer(oauth_index)
    assert lock_index < oauth_index
  end

  test "bounds retained audit history per user", %{user: user} do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_app_notification_audit_limit, 500 -> 3
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    for _index <- 1..5 do
      assert :ok =
               NotificationAudits.record(
                 user,
                 "https://app.example",
                 "https://app.example/ap/actor",
                 :permission_denied
               )
    end

    assert length(NotificationAudits.list_for_user(user)) == 3
  end

  test "fails closed for malformed inputs", %{user: user} do
    malformed_user_id = String.duplicate("!", 18)

    assert {:error, :invalid_decision} =
             NotificationConsents.decide(user.id, "https://app.example", :maybe)

    assert {:error, :notifications_not_declared} =
             NotificationConsents.decide(user.id, "not an origin", :granted)

    assert NotificationConsents.state(nil, "https://app.example") == :prompt
    assert NotificationConsents.state("not-a-flake-id", "https://app.example") == :prompt
    assert NotificationConsents.state(malformed_user_id, "https://app.example") == :prompt

    assert {:error, _reason} =
             NotificationConsents.decide(
               "not-a-flake-id",
               "https://app.example",
               :granted
             )

    assert {:error, :invalid_user} =
             NotificationConsents.decide(
               malformed_user_id,
               "https://app.example",
               :granted
             )

    assert NotificationConsents.list_for_user(nil) == []
    assert NotificationConsents.list_for_user("not-a-flake-id") == []
    assert NotificationConsents.list_for_user(malformed_user_id) == []
    assert :ok = NotificationConsents.revoke(nil, "https://app.example")
    assert :ok = NotificationConsents.revoke("not-a-flake-id", "https://app.example")
    assert :ok = NotificationConsents.revoke(malformed_user_id, "https://app.example")
  end

  test "revoking an absent consent is idempotent and does not broadcast or audit", %{user: user} do
    Permissions.subscribe(user.id)

    assert :ok = NotificationConsents.revoke(user.id, "https://app.example")
    refute_receive {:mini_app_permission_revoked, _, _}
    assert NotificationAudits.list_for_user(user) == []
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

  defp grant_oauth(application, user) do
    verifier = String.duplicate("n", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert {:ok, code} =
             OAuth.create_authorization_code(
               application,
               user,
               "https://app.example/oauth/callback",
               "read",
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

    token
  end

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    handler_id = {__MODULE__, System.unique_integer([:positive])}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:egregoros, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent, do: send(parent, {:notification_consent_query, metadata.query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, flush_repo_queries([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp flush_repo_queries(queries) do
    receive do
      {:notification_consent_query, query} -> flush_repo_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp enable_mini_apps, do: deny_mini_apps([])

  defp deny_mini_apps(denylist) do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> denylist
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)
  end
end
