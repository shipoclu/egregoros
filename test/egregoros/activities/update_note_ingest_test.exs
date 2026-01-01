defmodule Egregoros.Activities.UpdateNoteIngestTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users

  @public "https://www.w3.org/ns/activitystreams#Public"

  test "ingest applies Update edits to an existing Note" do
    {:ok, inbox_user} = Users.create_local_user("inbox-user")
    actor_ap_id = "https://remote.example/users/alice"

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: inbox_user.ap_id,
               object: actor_ap_id,
               activity_ap_id: "https://egregoros.example/activities/follow/update-note-targeting"
             })

    note_id = "https://remote.example/objects/1"

    assert {:ok, %Object{} = note_object} =
             Pipeline.ingest(
               %{
                 "id" => note_id,
                 "type" => "Note",
                 "attributedTo" => actor_ap_id,
                 "to" => [@public],
                 "cc" => [actor_ap_id <> "/followers"],
                 "content" => "old"
               },
               local: false
             )

    assert note_object.data["content"] == "old"

    update = %{
      "id" => "https://remote.example/activities/update/1",
      "type" => "Update",
      "actor" => actor_ap_id,
      "to" => [@public],
      "cc" => [actor_ap_id <> "/followers"],
      "object" => %{
        "id" => note_id,
        "type" => "Note",
        "attributedTo" => actor_ap_id,
        "to" => [@public],
        "cc" => [actor_ap_id <> "/followers"],
        "content" => "new"
      }
    }

    assert {:ok, %Object{} = update_object} =
             Pipeline.ingest(update, local: false, inbox_user_ap_id: inbox_user.ap_id)

    assert update_object.type == "Update"
    assert update_object.object == note_id

    note_object = Objects.get_by_ap_id(note_id)
    assert note_object.data["content"] == "new"
  end

  test "cast_and_validate rejects Update when a Note's attributedTo does not match the Update actor" do
    update = %{
      "id" => "https://remote.example/activities/update/2",
      "type" => "Update",
      "actor" => "https://remote.example/users/alice",
      "object" => %{
        "id" => "https://remote.example/objects/2",
        "type" => "Note",
        "attributedTo" => "https://remote.example/users/bob",
        "content" => "hello"
      }
    }

    assert {:error, %Ecto.Changeset{}} = Egregoros.Activities.Update.cast_and_validate(update)
  end
end
