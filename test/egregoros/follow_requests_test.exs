defmodule Egregoros.FollowRequestsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Activities.Follow
  alias Egregoros.Activities.Undo
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users

  test "outgoing follow to remote user is stored as a follow request until accepted" do
    {:ok, alice} = Users.create_local_user("alice")

    {:ok, bob} =
      Users.create_user(%{
        nickname: "bob",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    {:ok, follow_object} = Pipeline.ingest(Follow.build(alice, bob), local: true)

    assert Relationships.get_by_type_actor_object("Follow", alice.ap_id, bob.ap_id) == nil

    assert %{activity_ap_id: activity_ap_id} =
             Relationships.get_by_type_actor_object("FollowRequest", alice.ap_id, bob.ap_id)

    assert activity_ap_id == follow_object.ap_id
  end

  test "accepting a follow request finalizes the follow relationship" do
    {:ok, alice} = Users.create_local_user("alice")

    {:ok, bob} =
      Users.create_user(%{
        nickname: "bob",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    {:ok, follow_object} = Pipeline.ingest(Follow.build(alice, bob), local: true)

    accept = %{
      "id" => "https://remote.example/activities/accept/1",
      "type" => "Accept",
      "actor" => bob.ap_id,
      "object" => follow_object.data
    }

    assert {:ok, _} = Pipeline.ingest(accept, local: false)

    assert %{activity_ap_id: activity_ap_id} =
             Relationships.get_by_type_actor_object("Follow", alice.ap_id, bob.ap_id)

    assert activity_ap_id == follow_object.ap_id
    assert Relationships.get_by_type_actor_object("FollowRequest", alice.ap_id, bob.ap_id) == nil
  end

  test "undoing a follow request removes the pending relationship" do
    {:ok, alice} = Users.create_local_user("alice")

    {:ok, bob} =
      Users.create_user(%{
        nickname: "bob",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    {:ok, follow_object} = Pipeline.ingest(Follow.build(alice, bob), local: true)

    assert Relationships.get_by_type_actor_object("FollowRequest", alice.ap_id, bob.ap_id)

    undo = Undo.build(alice, follow_object.ap_id)
    assert {:ok, _} = Pipeline.ingest(undo, local: true)

    assert Relationships.get_by_type_actor_object("FollowRequest", alice.ap_id, bob.ap_id) == nil
    assert Relationships.get_by_type_actor_object("Follow", alice.ap_id, bob.ap_id) == nil
    assert Objects.get_by_ap_id(follow_object.ap_id) == nil
  end

  test "following a locked local user creates a follow request until accepted" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    {:ok, bob} = Users.update_profile(bob, %{locked: true})

    {:ok, follow_object} = Pipeline.ingest(Follow.build(alice, bob), local: true)

    assert Relationships.get_by_type_actor_object("Follow", alice.ap_id, bob.ap_id) == nil

    assert %{activity_ap_id: activity_ap_id} =
             Relationships.get_by_type_actor_object("FollowRequest", alice.ap_id, bob.ap_id)

    assert activity_ap_id == follow_object.ap_id
  end

  test "rejecting a follow request removes the pending relationship" do
    {:ok, alice} = Users.create_local_user("alice")

    {:ok, bob} =
      Users.create_user(%{
        nickname: "bob",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    {:ok, follow_object} = Pipeline.ingest(Follow.build(alice, bob), local: true)

    assert Relationships.get_by_type_actor_object("FollowRequest", alice.ap_id, bob.ap_id)

    reject = %{
      "id" => "https://remote.example/activities/reject/1",
      "type" => "Reject",
      "actor" => bob.ap_id,
      "object" => follow_object.data
    }

    assert {:ok, _} = Pipeline.ingest(reject, local: false)

    assert Relationships.get_by_type_actor_object("FollowRequest", alice.ap_id, bob.ap_id) == nil
    assert Relationships.get_by_type_actor_object("Follow", alice.ap_id, bob.ap_id) == nil
  end

  test "an Accept cannot invent a follow from an uncorrelated embedded object" do
    {:ok, alice} = Users.create_local_user("alice-forged-accept")

    forged_follow = %{
      "id" => "https://attacker.example/activities/follow/invented",
      "type" => "Follow",
      "actor" => alice.ap_id,
      "object" => "https://attacker.example/users/mallory"
    }

    accept = %{
      "id" => "https://attacker.example/activities/accept/invented",
      "type" => "Accept",
      "actor" => "https://attacker.example/users/mallory",
      "object" => forged_follow
    }

    assert {:error, :uncorrelated_follow_response} = Pipeline.ingest(accept, local: false)

    refute Relationships.get_by_type_actor_object(
             "Follow",
             alice.ap_id,
             forged_follow["object"]
           )
  end

  test "only the target of the exact pending Follow may accept it" do
    {:ok, alice} = Users.create_local_user("alice-wrong-acceptor")

    {:ok, bob} =
      Users.create_user(%{
        nickname: "bob-wrong-acceptor",
        ap_id: "https://remote.example/users/bob-wrong-acceptor",
        inbox: "https://remote.example/users/bob-wrong-acceptor/inbox",
        outbox: "https://remote.example/users/bob-wrong-acceptor/outbox",
        public_key: "remote-key",
        local: false
      })

    {:ok, follow} = Pipeline.ingest(Follow.build(alice, bob), local: true)

    forged_accept = %{
      "id" => "https://remote.example/activities/accept/wrong-actor",
      "type" => "Accept",
      "actor" => "https://remote.example/users/mallory",
      "object" => follow.data
    }

    assert {:error, :uncorrelated_follow_response} =
             Pipeline.ingest(forged_accept, local: false)

    assert Relationships.get_by_type_actor_object("FollowRequest", alice.ap_id, bob.ap_id)
    refute Relationships.get_by_type_actor_object("Follow", alice.ap_id, bob.ap_id)
  end

  test "a mislabeled embedded object cannot bypass pending Follow acceptance authorization" do
    {:ok, alice} = Users.create_local_user("alice-mislabeled-accept")

    {:ok, bob} =
      Users.create_user(%{
        nickname: "bob-mislabeled-accept",
        ap_id: "https://remote.example/users/bob-mislabeled-accept",
        inbox: "https://remote.example/users/bob-mislabeled-accept/inbox",
        outbox: "https://remote.example/users/bob-mislabeled-accept/outbox",
        public_key: "remote-key",
        local: false
      })

    {:ok, follow} = Pipeline.ingest(Follow.build(alice, bob), local: true)

    forged_accept = %{
      "id" => "https://mallory.example/activities/accept/mislabeled",
      "type" => "Accept",
      "actor" => "https://mallory.example/users/mallory",
      "object" => Map.put(follow.data, "type", "Offer")
    }

    assert {:error, :uncorrelated_follow_response} =
             Pipeline.ingest(forged_accept, local: false)

    assert Relationships.get_by_type_actor_object("FollowRequest", alice.ap_id, bob.ap_id)
    refute Relationships.get_by_type_actor_object("Follow", alice.ap_id, bob.ap_id)
  end

  test "a multi-type embedded object cannot bypass pending Follow rejection authorization" do
    {:ok, alice} = Users.create_local_user("alice-multitype-reject")

    {:ok, bob} =
      Users.create_user(%{
        nickname: "bob-multitype-reject",
        ap_id: "https://remote.example/users/bob-multitype-reject",
        inbox: "https://remote.example/users/bob-multitype-reject/inbox",
        outbox: "https://remote.example/users/bob-multitype-reject/outbox",
        public_key: "remote-key",
        local: false
      })

    {:ok, follow} = Pipeline.ingest(Follow.build(alice, bob), local: true)

    forged_reject = %{
      "id" => "https://mallory.example/activities/reject/multitype",
      "type" => "Reject",
      "actor" => "https://mallory.example/users/mallory",
      "object" => Map.put(follow.data, "type", ["Offer", "Follow"])
    }

    assert {:error, :uncorrelated_follow_response} =
             Pipeline.ingest(forged_reject, local: false)

    assert Relationships.get_by_type_actor_object("FollowRequest", alice.ap_id, bob.ap_id)
  end

  test "Reject cannot remove an established Follow without a pending request" do
    {:ok, alice} = Users.create_local_user("alice-established-follow")

    {:ok, bob} =
      Users.create_user(%{
        nickname: "bob-established-follow",
        ap_id: "https://remote.example/users/bob-established-follow",
        inbox: "https://remote.example/users/bob-established-follow/inbox",
        outbox: "https://remote.example/users/bob-established-follow/outbox",
        public_key: "remote-key",
        local: false
      })

    {:ok, follow} = Pipeline.ingest(Follow.build(alice, bob), local: true)

    accept = %{
      "id" => "https://remote.example/activities/accept/established",
      "type" => "Accept",
      "actor" => bob.ap_id,
      "object" => follow.data
    }

    assert {:ok, _} = Pipeline.ingest(accept, local: false)
    assert Relationships.get_by_type_actor_object("Follow", alice.ap_id, bob.ap_id)

    reject = %{
      "id" => "https://remote.example/activities/reject/established",
      "type" => "Reject",
      "actor" => bob.ap_id,
      "object" => follow.data
    }

    assert {:error, :uncorrelated_follow_response} = Pipeline.ingest(reject, local: false)
    assert Relationships.get_by_type_actor_object("Follow", alice.ap_id, bob.ap_id)
  end
end
