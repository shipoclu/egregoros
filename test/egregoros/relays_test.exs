defmodule Egregoros.RelaysTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Activities.Follow
  alias Egregoros.Federation.InstanceActor
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Relay
  alias Egregoros.Relationships
  alias Egregoros.Relays
  alias Egregoros.Repo
  alias Egregoros.Users

  test "subscribed?/1 returns false for blank or non-binary values" do
    refute Relays.subscribed?("")
    refute Relays.subscribed?("   ")
    refute Relays.subscribed?(nil)
    refute Relays.subscribed?(123)
  end

  test "subscribe/1 rejects invalid relay ids early" do
    assert {:error, :invalid_relay} = Relays.subscribe(nil)

    assert {:error, _} = Relays.subscribe("")
    assert {:error, _} = Relays.subscribe("   ")
    assert {:error, _} = Relays.subscribe("mailto:relay@example.com")
  end

  test "list_relays/0 is ordered by ap_id" do
    assert {:ok, r2} =
             %Relay{} |> Relay.changeset(%{ap_id: "https://b.example/actor"}) |> Repo.insert()

    assert {:ok, r1} =
             %Relay{} |> Relay.changeset(%{ap_id: "https://a.example/actor"}) |> Repo.insert()

    assert [^r1, ^r2] = Relays.list_relays()
  end

  test "delete_by_ap_id/1 is a no-op for blank values" do
    assert :ok = Relays.delete_by_ap_id("")
    assert :ok = Relays.delete_by_ap_id("   ")
    assert :ok = Relays.delete_by_ap_id(nil)
  end

  test "unsubscribe/1 returns an error when the relay doesn't exist" do
    assert {:error, :not_found} = Relays.unsubscribe(123)
    assert {:error, :invalid_relay} = Relays.unsubscribe(-1)
    assert {:error, :invalid_relay} = Relays.unsubscribe("nope")
  end

  test "unsubscribe/1 deletes the relay and undoes the follow relationship" do
    {:ok, internal} = InstanceActor.get_actor()

    {:ok, relay_user} =
      Users.create_user(%{
        nickname: "relay",
        ap_id: "https://relay.example/actor",
        inbox: "https://relay.example/inbox",
        outbox: "https://relay.example/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    assert {:ok, follow_object} = Pipeline.ingest(Follow.build(internal, relay_user), local: true)

    assert Relationships.get_by_type_actor_object(
             "FollowRequest",
             internal.ap_id,
             relay_user.ap_id
           )

    assert {:ok, relay} =
             %Relay{}
             |> Relay.changeset(%{ap_id: relay_user.ap_id})
             |> Repo.insert()

    assert Relays.subscribed?(relay_user.ap_id)

    relay_id = relay.id

    assert {:ok, %Relay{id: ^relay_id}} = Relays.unsubscribe(relay_id)

    refute Relays.subscribed?(relay_user.ap_id)

    assert Relationships.get_by_type_actor_object(
             "FollowRequest",
             internal.ap_id,
             relay_user.ap_id
           ) ==
             nil

    assert Repo.get(Relay, relay.id) == nil

    assert Objects.get_by_type_actor_object("Undo", internal.ap_id, follow_object.ap_id)
  end

  test "incoming Reject of a relay follow removes the relay subscription" do
    {:ok, internal} = InstanceActor.get_actor()

    {:ok, relay_user} =
      Users.create_user(%{
        nickname: "relay",
        ap_id: "https://relay.example/actor",
        inbox: "https://relay.example/inbox",
        outbox: "https://relay.example/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    assert {:ok, follow_object} = Pipeline.ingest(Follow.build(internal, relay_user), local: true)

    assert Relationships.get_by_type_actor_object(
             "FollowRequest",
             internal.ap_id,
             relay_user.ap_id
           )

    assert {:ok, _relay} =
             %Relay{}
             |> Relay.changeset(%{ap_id: relay_user.ap_id})
             |> Repo.insert()

    assert Relays.subscribed?(relay_user.ap_id)

    reject = %{
      "id" => "https://relay.example/activities/reject/1",
      "type" => "Reject",
      "actor" => relay_user.ap_id,
      "object" => follow_object.data
    }

    assert {:ok, _} =
             Pipeline.ingest(reject,
               local: false,
               inbox_user_ap_id: internal.ap_id
             )

    assert Relationships.get_by_type_actor_object(
             "FollowRequest",
             internal.ap_id,
             relay_user.ap_id
           ) ==
             nil

    assert Relationships.get_by_type_actor_object("Follow", internal.ap_id, relay_user.ap_id) ==
             nil

    refute Relays.subscribed?(relay_user.ap_id)
  end
end
