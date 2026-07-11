defmodule Egregoros.MiniApps.NotificationConsentsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.NotificationConsents
  alias Egregoros.MiniApps.Permissions
  alias Egregoros.Users

  setup do
    enable_mini_apps()
    {:ok, _declaration, :created} = Declarations.ensure(manifest_fixture())
    {:ok, user} = Users.create_local_user("mini-app-notification-consent-user")
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
  end

  test "fails closed for malformed inputs", %{user: user} do
    assert {:error, :invalid_decision} =
             NotificationConsents.decide(user.id, "https://app.example", :maybe)

    assert {:error, :notifications_not_declared} =
             NotificationConsents.decide(user.id, "not an origin", :granted)

    assert NotificationConsents.state(nil, "https://app.example") == :prompt
    assert NotificationConsents.state("not-a-flake-id", "https://app.example") == :prompt

    assert {:error, _reason} =
             NotificationConsents.decide(
               "not-a-flake-id",
               "https://app.example",
               :granted
             )

    assert NotificationConsents.list_for_user(nil) == []
    assert :ok = NotificationConsents.revoke(nil, "https://app.example")
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
