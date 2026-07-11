defmodule Egregoros.MiniApps.NotificationAuditsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.NotificationAudits
  alias Egregoros.Users

  test "stores only bounded notification security metadata" do
    {:ok, user} = Users.create_local_user("mini-app-audit-user")

    assert :ok =
             NotificationAudits.record(
               user,
               "https://app.example",
               "https://app.example/ap/actor",
               :delivery_suppressed,
               :consent_missing
             )

    assert [audit] = NotificationAudits.list_for_user(user)
    assert audit.event == :delivery_suppressed
    assert audit.reason == "consent_missing"
    assert audit.app_origin == "https://app.example"
    assert audit.app_actor_url == "https://app.example/ap/actor"

    refute Map.has_key?(audit, :content)
    refute Map.has_key?(audit, :activity_id)
    refute Map.has_key?(audit, :note_id)
    refute Map.has_key?(audit, :recipient_actor)
  end

  test "rejects unbounded or unknown audit values" do
    {:ok, user} = Users.create_local_user("mini-app-audit-invalid-user")

    assert {:error, :invalid_audit} =
             NotificationAudits.record(
               user,
               "https://app.example",
               "https://app.example/ap/actor",
               :unknown_event,
               String.duplicate("x", 500)
             )

    assert {:error, :invalid_audit} =
             NotificationAudits.record(
               user,
               "https://app.example",
               "https://app.example/ap/actor",
               :delivery_suppressed,
               String.duplicate("x", 65)
             )

    assert NotificationAudits.list_for_user(user) == []
    assert NotificationAudits.list_for_user(nil) == []
  end
end
