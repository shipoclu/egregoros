defmodule Egregoros.Workers.RefreshRemoteFollowingGraphsDailyTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Relationships
  alias Egregoros.Users
  alias Egregoros.Workers.RefreshRemoteFollowingGraph
  alias Egregoros.Workers.RefreshRemoteFollowingGraphsDaily

  test "enqueues graph refresh jobs for remote accounts followed by local users" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, dave} = Users.create_local_user("dave")
    {:ok, local_buddy} = Users.create_local_user("carol")

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

    {:ok, eve} =
      Users.create_user(%{
        nickname: "eve",
        domain: "other.example",
        ap_id: "https://other.example/users/eve",
        inbox: "https://other.example/users/eve/inbox",
        outbox: "https://other.example/users/eve/outbox",
        public_key: "other-key",
        private_key: nil,
        local: false
      })

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: alice.ap_id,
               object: bob.ap_id,
               activity_ap_id: nil
             })

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: alice.ap_id,
               object: eve.ap_id,
               activity_ap_id: nil
             })

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: alice.ap_id,
               object: local_buddy.ap_id,
               activity_ap_id: nil
             })

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: dave.ap_id,
               object: bob.ap_id,
               activity_ap_id: nil
             })

    assert :ok = perform_job(RefreshRemoteFollowingGraphsDaily, %{})

    assert_enqueued(worker: RefreshRemoteFollowingGraph, args: %{"ap_id" => bob.ap_id})
    assert_enqueued(worker: RefreshRemoteFollowingGraph, args: %{"ap_id" => eve.ap_id})
    refute_enqueued(worker: RefreshRemoteFollowingGraph, args: %{"ap_id" => local_buddy.ap_id})

    ap_ids =
      all_enqueued(worker: RefreshRemoteFollowingGraph)
      |> Enum.map(& &1.args["ap_id"])

    assert Enum.sort(ap_ids) == Enum.sort(Enum.uniq(ap_ids))
  end
end
