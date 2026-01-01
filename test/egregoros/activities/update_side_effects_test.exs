defmodule Egregoros.Activities.UpdateSideEffectsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Activities.Update
  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users
  alias Egregoros.Workers.DeliverActivity

  @public "https://www.w3.org/ns/activitystreams#Public"

  test "side_effects is a no-op for non-Update objects" do
    assert Update.side_effects(%{}, []) == :ok
  end

  test "local Update delivers to remote followers and explicit recipients" do
    unique = Ecto.UUID.generate()
    {:ok, actor} = Users.create_local_user("alice-#{unique}")

    {:ok, remote_follower} =
      Users.create_user(%{
        nickname: "bob",
        domain: "remote.example",
        ap_id: "https://remote.example/users/bob-#{unique}",
        inbox: "https://remote.example/users/bob-#{unique}/inbox",
        outbox: "https://remote.example/users/bob-#{unique}/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    {:ok, remote_recipient} =
      Users.create_user(%{
        nickname: "carol",
        domain: "remote.example",
        ap_id: "https://remote.example/users/carol-#{unique}",
        inbox: "https://remote.example/users/carol-#{unique}/inbox",
        outbox: "https://remote.example/users/carol-#{unique}/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    {:ok, local_follower} = Users.create_local_user("local-follower-#{unique}")

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: remote_follower.ap_id,
               object: actor.ap_id,
               activity_ap_id: "https://remote.example/activities/follow/#{unique}"
             })

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: local_follower.ap_id,
               object: actor.ap_id,
               activity_ap_id: actor.ap_id <> "/activities/follow/local-#{unique}"
             })

    note_id = actor.ap_id <> "/objects/" <> Ecto.UUID.generate()

    note =
      %{
        "id" => note_id,
        "type" => "Note",
        "attributedTo" => actor.ap_id,
        "to" => [@public, remote_recipient.ap_id, "https://missing.example/users/missing-#{unique}"],
        "cc" => [actor.ap_id <> "/followers"],
        "content" => "<p>Hello</p>"
      }

    update = Update.build(actor, note)

    assert {:ok, update_object} = Pipeline.ingest(update, local: true)

    assert_enqueued(
      worker: DeliverActivity,
      args: %{
        "user_id" => actor.id,
        "inbox_url" => remote_follower.inbox,
        "activity" => update_object.data
      }
    )

    assert_enqueued(
      worker: DeliverActivity,
      args: %{
        "user_id" => actor.id,
        "inbox_url" => remote_recipient.inbox,
        "activity" => update_object.data
      }
    )

    refute_enqueued(
      worker: DeliverActivity,
      args: %{
        "user_id" => actor.id,
        "inbox_url" => local_follower.inbox,
        "activity" => update_object.data
      }
    )
  end
end

