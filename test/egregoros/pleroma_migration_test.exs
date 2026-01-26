defmodule Egregoros.PleromaMigrationTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.PleromaMigration
  alias Egregoros.Object
  alias Egregoros.Repo
  alias Egregoros.User

  test "import_users/1 inserts users and returns a summary" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    nickname = "alice#{System.unique_integer([:positive])}"
    ap_id = "https://example.com/users/#{nickname}"

    users = [
      %{
        id: FlakeId.get(),
        nickname: nickname,
        domain: nil,
        ap_id: ap_id,
        inbox: ap_id <> "/inbox",
        outbox: ap_id <> "/outbox",
        public_key: "PUB",
        private_key: "PRIV",
        local: true,
        inserted_at: now,
        updated_at: now
      }
    ]

    assert %{inserted: 1, attempted: 1} = PleromaMigration.import_users(users)

    assert %User{nickname: ^nickname} = Repo.get_by(User, nickname: nickname, local: true)
  end

  test "import_statuses/1 preserves Pleroma status ids for Create activities" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    nickname = "alice#{System.unique_integer([:positive])}"
    actor_ap_id = "https://example.com/users/#{nickname}"

    status_id = FlakeId.get()
    uuid = Ecto.UUID.generate()
    note_ap_id = "https://example.com/objects/#{uuid}"
    activity_ap_id = "https://example.com/activities/#{Ecto.UUID.generate()}"

    note = %{
      "id" => note_ap_id,
      "type" => "Note",
      "actor" => actor_ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [actor_ap_id <> "/followers"],
      "content" => "Hello from Pleroma migration"
    }

    create = %{
      "id" => activity_ap_id,
      "type" => "Create",
      "actor" => actor_ap_id,
      "to" => note["to"],
      "cc" => note["cc"],
      "object" => note_ap_id,
      "published" => DateTime.to_iso8601(now)
    }

    statuses = [
      %{
        activity_id: status_id,
        activity: create,
        object: note,
        local: true,
        inserted_at: now,
        updated_at: now
      }
    ]

    assert %{inserted: 2, attempted: 1} = PleromaMigration.import_statuses(statuses)

    assert %Object{id: ^status_id} = Repo.get_by(Object, ap_id: note_ap_id)
  end
end
