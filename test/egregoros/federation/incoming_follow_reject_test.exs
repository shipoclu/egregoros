defmodule Egregoros.Federation.IncomingFollowRejectTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.Activities.Reject
  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users
  alias Egregoros.Workers.DeliverActivity

  test "rejecting a follow request for a locked local user removes the pending relationship and delivers Reject" do
    {:ok, local} = Users.create_local_user("alice")
    {:ok, _} = Users.update_profile(local, %{locked: true})

    {:ok, remote} =
      Users.create_user(%{
        nickname: "bob",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----\n",
        local: false
      })

    follow = %{
      "id" => "https://remote.example/activities/follow/reject-1",
      "type" => "Follow",
      "actor" => remote.ap_id,
      "object" => local.ap_id
    }

    assert {:ok, follow_object} =
             Pipeline.ingest(follow,
               local: false,
               inbox_user_ap_id: local.ap_id
             )

    assert Relationships.get_by_type_actor_object("FollowRequest", remote.ap_id, local.ap_id)

    Egregoros.HTTP.Mock
    |> expect(:post, fn url, body, _headers ->
      assert url == remote.inbox

      decoded = Jason.decode!(body)
      assert decoded["type"] == "Reject"
      assert decoded["actor"] == local.ap_id
      assert decoded["object"]["id"] == follow["id"]
      assert decoded["object"]["type"] == "Follow"

      {:ok, %{status: 202, body: "", headers: []}}
    end)

    assert {:ok, _reject_object} =
             Pipeline.ingest(Reject.build(local, follow_object), local: true)

    assert Relationships.get_by_type_actor_object("FollowRequest", remote.ap_id, local.ap_id) ==
             nil

    assert Relationships.get_by_type_actor_object("Follow", remote.ap_id, local.ap_id) == nil

    args =
      all_enqueued(worker: DeliverActivity)
      |> Enum.map(& &1.args)
      |> Enum.find(fn
        %{"activity" => %{"type" => "Reject"}} -> true
        _ -> false
      end)

    assert is_map(args)
    assert :ok = perform_job(DeliverActivity, args)
  end
end
