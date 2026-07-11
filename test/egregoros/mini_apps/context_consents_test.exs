defmodule Egregoros.MiniApps.ContextConsentsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.ContextConsents
  alias Egregoros.MiniApps.Permissions
  alias Egregoros.Users

  setup do
    enable_mini_apps()
    :ok
  end

  test "grants one reusable consent per user and exact app origin" do
    {:ok, user} = Users.create_local_user("mini-app-context-user")

    refute ContextConsents.approved?(user.id, "https://app.example")
    assert {:ok, first} = ContextConsents.grant(user.id, "https://app.example")
    assert ContextConsents.approved?(user.id, "https://app.example")

    assert {:ok, second} = ContextConsents.grant(user.id, "https://app.example")
    assert first.id == second.id

    refute ContextConsents.approved?(user.id, "https://other.example")
  end

  test "rejects malformed origins and applies current domain policy" do
    {:ok, user} = Users.create_local_user("mini-app-context-policy-user")

    assert {:error, changeset} = ContextConsents.grant(user.id, "http://app.example")
    assert "is invalid" in errors_on(changeset).app_origin

    assert {:ok, _consent} = ContextConsents.grant(user.id, "https://app.example")

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> ["app.example"]
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    refute ContextConsents.approved?(user.id, "https://app.example")
  end

  test "revokes the reusable disclosure" do
    {:ok, user} = Users.create_local_user("mini-app-context-revoke-user")
    assert {:ok, consent} = ContextConsents.grant(user.id, "https://app.example")
    assert ContextConsents.list_for_user(user.id) == [consent]
    Permissions.subscribe(user.id)
    assert :ok = ContextConsents.revoke(user.id, "https://app.example")
    assert_receive {:mini_app_permission_revoked, "https://app.example", :context}
    refute ContextConsents.approved?(user.id, "https://app.example")
    assert ContextConsents.list_for_user(user.id) == []
  end

  test "fails closed for invalid identifiers and origins" do
    refute ContextConsents.approved?(nil, "https://app.example")
    refute ContextConsents.approved?("not-a-flake-id", "https://app.example")
    refute ContextConsents.approved?("not-a-flake-id", "not an origin")
    assert :ok = ContextConsents.revoke("not-a-flake-id", "https://app.example")
    assert ContextConsents.list_for_user(nil) == []
    assert ContextConsents.list_for_user("not-a-flake-id") == []
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
