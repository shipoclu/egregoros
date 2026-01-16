defmodule EgregorosWeb.InstanceFollowCollectionControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.Federation.InstanceActor
  alias Egregoros.Relationships
  alias Egregoros.Users

  test "GET /followers returns an OrderedCollection of follower actor ids", %{conn: conn} do
    {:ok, instance_actor} = InstanceActor.get_actor()

    {:ok, follower} =
      Users.create_user(%{
        nickname: "follower",
        domain: "remote.example",
        ap_id: "https://remote.example/users/follower",
        inbox: "https://remote.example/users/follower/inbox",
        outbox: "https://remote.example/users/follower/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    assert {:ok, _follow} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: follower.ap_id,
               object: instance_actor.ap_id
             })

    conn = get(conn, "/followers")
    response = json_response(conn, 200)

    assert response["@context"] == "https://www.w3.org/ns/activitystreams"
    assert response["type"] == "OrderedCollection"
    assert response["id"] == instance_actor.ap_id <> "/followers"
    assert response["totalItems"] == 1
    assert response["orderedItems"] == [follower.ap_id]
  end

  test "GET /following returns an OrderedCollection of followed actor ids", %{conn: conn} do
    {:ok, instance_actor} = InstanceActor.get_actor()

    {:ok, target} =
      Users.create_user(%{
        nickname: "target",
        domain: "remote.example",
        ap_id: "https://remote.example/users/target",
        inbox: "https://remote.example/users/target/inbox",
        outbox: "https://remote.example/users/target/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    assert {:ok, _follow} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: instance_actor.ap_id,
               object: target.ap_id
             })

    conn = get(conn, "/following")
    response = json_response(conn, 200)

    assert response["@context"] == "https://www.w3.org/ns/activitystreams"
    assert response["type"] == "OrderedCollection"
    assert response["id"] == instance_actor.ap_id <> "/following"
    assert response["totalItems"] == 1
    assert response["orderedItems"] == [target.ap_id]
  end
end
