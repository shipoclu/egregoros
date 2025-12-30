defmodule Egregoros.TimelinePubSubTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Pipeline
  alias Egregoros.Publish
  alias Egregoros.Timeline
  alias Egregoros.Users

  test "broadcasts announces to the public timeline topic" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    {:ok, create} = Publish.post_note(alice, "hello")

    bob_ap_id = bob.ap_id
    object_ap_id = create.object

    Timeline.subscribe_public()

    {:ok, _announce} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/activities/announce/1",
          "type" => "Announce",
          "actor" => bob_ap_id,
          "object" => object_ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        },
        local: true
      )

    assert_receive {:post_created, %{type: "Announce", actor: ^bob_ap_id, object: ^object_ap_id}}
  end
end
