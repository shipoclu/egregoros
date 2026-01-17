defmodule Egregoros.Activities.AcceptSideEffectsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Activities.Follow
  alias Egregoros.Pipeline
  alias Egregoros.Users
  alias Egregoros.Workers.RefreshRemoteFollowingGraph

  test "enqueues a follow-graph refresh when a remote user accepts a local follow" do
    {:ok, alice} = Users.create_local_user("alice")

    {:ok, bob} =
      Users.create_user(%{
        nickname: "bob",
        domain: "remote.example",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    assert {:ok, follow_object} = Pipeline.ingest(Follow.build(alice, bob), local: true)

    accept_activity = %{
      "id" => "https://remote.example/activities/accept/" <> Ecto.UUID.generate(),
      "type" => "Accept",
      "actor" => bob.ap_id,
      "object" => follow_object.data,
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    assert {:ok, _accept_object} = Pipeline.ingest(accept_activity, local: false)

    assert_enqueued(worker: RefreshRemoteFollowingGraph, args: %{"ap_id" => bob.ap_id})
  end

  test "does not enqueue a follow-graph refresh when the accepted follow target is local" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    assert {:ok, follow_object} = Pipeline.ingest(Follow.build(alice, bob), local: true)

    accept_activity = %{
      "id" => "https://egregoros.local/activities/accept/" <> Ecto.UUID.generate(),
      "type" => "Accept",
      "actor" => bob.ap_id,
      "object" => follow_object.data,
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    assert {:ok, _accept_object} = Pipeline.ingest(accept_activity, local: true)

    refute_enqueued(worker: RefreshRemoteFollowingGraph)
  end
end
