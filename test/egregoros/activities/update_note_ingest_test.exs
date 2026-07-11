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
                 "published" => "2026-01-01T00:00:00Z",
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
        "updated" => "2026-01-02T00:00:00Z",
        "content" => "new"
      }
    }

    assert {:ok, %Object{} = update_object} =
             Pipeline.ingest(update, local: false, inbox_user_ap_id: inbox_user.ap_id)

    assert update_object.type == "Update"
    assert update_object.object == note_id

    note_object = Objects.get_by_ap_id(note_id)
    assert note_object.data["content"] == "new"

    assert {:ok, %Object{id: replay_id}} =
             Pipeline.ingest(update, local: false, inbox_user_ap_id: inbox_user.ap_id)

    assert replay_id == update_object.id
    assert Objects.get_by_ap_id(note_id).data["content"] == "new"
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

  test "a same-origin peer cannot update a note owned by another actor" do
    bob = "https://remote.example/users/bob"
    alice = "https://remote.example/users/alice"
    note_id = "https://remote.example/objects/bobs-note"

    assert {:ok, %Object{}} =
             Pipeline.ingest(
               %{
                 "id" => note_id,
                 "type" => "Note",
                 "attributedTo" => bob,
                 "published" => "2026-01-01T00:00:00Z",
                 "to" => [@public],
                 "content" => "Bob wrote this"
               },
               local: false
             )

    update = %{
      "id" => "https://remote.example/activities/update/peer-takeover",
      "type" => "Update",
      "actor" => alice,
      "to" => [@public],
      "object" => %{
        "id" => note_id,
        "type" => "Note",
        "attributedTo" => alice,
        "updated" => "2026-01-02T00:00:00Z",
        "to" => [@public],
        "content" => "Alice replaced it"
      }
    }

    assert {:error, :unauthorized_update} = Pipeline.ingest(update, local: false)

    stored = Objects.get_by_ap_id(note_id)
    assert stored.actor == bob
    assert stored.data["content"] == "Bob wrote this"
    refute Objects.get_by_ap_id(update["id"])
  end

  test "a stale Update cannot roll back a newer note revision" do
    actor = "https://remote.example/users/alice"
    note_id = "https://remote.example/objects/versioned-note"

    assert {:ok, %Object{}} =
             Pipeline.ingest(
               %{
                 "id" => note_id,
                 "type" => "Note",
                 "attributedTo" => actor,
                 "published" => "2026-01-01T00:00:00Z",
                 "updated" => "2026-01-03T00:00:00Z",
                 "to" => [@public],
                 "content" => "newest"
               },
               local: false
             )

    stale_update = %{
      "id" => "https://remote.example/activities/update/stale",
      "type" => "Update",
      "actor" => actor,
      "to" => [@public],
      "object" => %{
        "id" => note_id,
        "type" => "Note",
        "attributedTo" => actor,
        "updated" => "2026-01-02T00:00:00Z",
        "to" => [@public],
        "content" => "older"
      }
    }

    assert {:error, :stale_update} = Pipeline.ingest(stale_update, local: false)
    assert Objects.get_by_ap_id(note_id).data["content"] == "newest"
  end

  test "an oversized remote Update cannot bypass the inbound Note content limit" do
    actor = "https://remote.example/users/oversized-update"
    note_id = "https://remote.example/objects/bounded-note"

    assert {:ok, %Object{}} =
             Pipeline.ingest(
               %{
                 "id" => note_id,
                 "type" => "Note",
                 "attributedTo" => actor,
                 "published" => "2026-01-01T00:00:00Z",
                 "to" => [@public],
                 "content" => "bounded"
               },
               local: false
             )

    update = %{
      "id" => "https://remote.example/activities/update/oversized",
      "type" => "Update",
      "actor" => actor,
      "to" => [@public],
      "object" => %{
        "id" => note_id,
        "type" => "Note",
        "attributedTo" => actor,
        "updated" => "2026-01-02T00:00:00Z",
        "to" => [@public],
        "content" => String.duplicate("x", 20_001)
      }
    }

    assert {:error, :too_long} = Pipeline.ingest(update, local: false)
    assert Objects.get_by_ap_id(note_id).data["content"] == "bounded"
    refute Objects.get_by_ap_id(update["id"])
  end
end
