defmodule Egregoros.MiniApps.PermissionsTest do
  use ExUnit.Case, async: true

  alias Egregoros.MiniApps.Permissions

  test "delivers bounded revocation events only to the affected user topic" do
    assert :ok = Permissions.subscribe("user-1")
    assert :ok = Permissions.notify_revoked("user-1", "https://app.example", :context)
    assert_receive {:mini_app_permission_revoked, "https://app.example", :context}

    assert :ok = Permissions.notify_revoked("user-2", "https://app.example", :wallet)
    refute_receive {:mini_app_permission_revoked, _, :wallet}

    assert :ok = Permissions.subscribe(nil)
    assert :ok = Permissions.notify_revoked(nil, nil, :unknown)
  end
end
