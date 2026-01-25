defmodule Egregoros.InboxTargetingTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.InboxTargeting
  alias Egregoros.Object
  alias Egregoros.Repo

  test "validate_addressed_or_followed/3 accepts activities addressed to inbox user" do
    inbox_user_ap_id = "https://example.com/users/alice"
    actor_ap_id = "https://remote.example/users/bob"

    activity = %{
      "id" => "https://remote.example/activities/1",
      "type" => "Note",
      "actor" => actor_ap_id,
      "to" => [inbox_user_ap_id],
      "cc" => []
    }

    assert :ok ==
             InboxTargeting.validate_addressed_or_followed(
               [local: false, inbox_user_ap_id: inbox_user_ap_id],
               activity,
               actor_ap_id
             )
  end

  test "validate_addressed_or_followed_or_object_owned/4 accepts when target object is owned by inbox user" do
    inbox_user_ap_id = "https://example.com/users/alice"
    object_ap_id = "https://remote.example/objects/1"

    _ =
      Repo.insert!(
        Object.changeset(%Object{}, %{
          ap_id: object_ap_id,
          type: "Note",
          actor: inbox_user_ap_id,
          data: %{}
        })
      )

    activity = %{
      "id" => "https://remote.example/activities/2",
      "type" => "Like",
      "actor" => "https://remote.example/users/bob",
      "object" => object_ap_id,
      "to" => [],
      "cc" => []
    }

    assert :ok ==
             InboxTargeting.validate_addressed_or_followed_or_object_owned(
               [local: false, inbox_user_ap_id: inbox_user_ap_id],
               activity,
               nil,
               object_ap_id
             )
  end

  test "validate_addressed_or_followed_or_addressed_to_object/4 accepts when embedded object is addressed to inbox user" do
    inbox_user_ap_id = "https://example.com/users/alice"
    actor_ap_id = "https://remote.example/users/bob"

    embedded_object = %{
      "id" => "https://remote.example/objects/2",
      "type" => "Note",
      "to" => [inbox_user_ap_id],
      "cc" => []
    }

    activity = %{
      "id" => "https://remote.example/activities/3",
      "type" => "Create",
      "actor" => actor_ap_id,
      "object" => embedded_object,
      "to" => [],
      "cc" => []
    }

    assert :ok ==
             InboxTargeting.validate_addressed_or_followed_or_addressed_to_object(
               [local: false, inbox_user_ap_id: inbox_user_ap_id],
               activity,
               actor_ap_id,
               embedded_object
             )
  end

  test "validate_addressed_or_followed/3 rejects when not targeted" do
    inbox_user_ap_id = "https://example.com/users/alice"
    actor_ap_id = "https://remote.example/users/bob"

    activity = %{
      "id" => "https://remote.example/activities/4",
      "type" => "Note",
      "actor" => actor_ap_id,
      "to" => [],
      "cc" => []
    }

    assert {:error, :not_targeted} ==
             InboxTargeting.validate_addressed_or_followed(
               [local: false, inbox_user_ap_id: inbox_user_ap_id],
               activity,
               actor_ap_id
             )
  end
end
