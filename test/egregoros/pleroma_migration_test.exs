defmodule Egregoros.PleromaMigrationTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.PleromaMigration
  alias Egregoros.PleromaMigration.Source
  alias Egregoros.Object
  alias Egregoros.Repo
  alias Egregoros.User

  setup do
    previous_impl = Application.get_env(:egregoros, Source)

    Application.put_env(:egregoros, Source, Source.Mock)

    on_exit(fn ->
      if is_nil(previous_impl) do
        Application.delete_env(:egregoros, Source)
      else
        Application.put_env(:egregoros, Source, previous_impl)
      end
    end)

    :ok
  end

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

  test "Source.list_users/0 and list_statuses/0 delegate to the configured source" do
    Source.Mock
    |> expect(:list_users, fn opts ->
      assert opts == []
      {:ok, []}
    end)
    |> expect(:list_statuses, fn opts ->
      assert opts == []
      {:ok, []}
    end)

    assert {:ok, []} = Source.list_users()
    assert {:ok, []} = Source.list_statuses()
  end

  test "run/1 imports users and statuses (including remote) via a source module" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    local_nickname = "alice#{System.unique_integer([:positive])}"
    local_actor_ap_id = "https://example.com/users/#{local_nickname}"

    local_user = %{
      id: FlakeId.get(),
      nickname: local_nickname,
      domain: nil,
      ap_id: local_actor_ap_id,
      inbox: local_actor_ap_id <> "/inbox",
      outbox: local_actor_ap_id <> "/outbox",
      public_key: "PUB",
      private_key: "PRIV",
      local: true,
      inserted_at: now,
      updated_at: now
    }

    remote_actor_ap_id = "https://remote.example/users/bob"
    status_id = FlakeId.get()
    note_ap_id = "https://remote.example/objects/#{Ecto.UUID.generate()}"
    activity_ap_id = "https://example.com/activities/#{Ecto.UUID.generate()}"

    note = %{
      "id" => note_ap_id,
      "type" => "Note",
      "actor" => remote_actor_ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "content" => "hello"
    }

    create = %{
      "id" => activity_ap_id,
      "type" => "Create",
      "actor" => remote_actor_ap_id,
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
        local: false,
        inserted_at: now,
        updated_at: now
      }
    ]

    Source.Mock
    |> expect(:list_users, fn _opts -> {:ok, [local_user]} end)
    |> expect(:list_statuses, fn _opts -> {:ok, statuses} end)

    local_user_id = local_user.id

    assert %{users: %{inserted: 1, attempted: 1}, statuses: %{attempted: 1}} =
             PleromaMigration.run()

    assert %User{id: ^local_user_id} = Repo.get_by(User, ap_id: local_actor_ap_id)
    assert %Object{id: ^status_id, local: false} = Repo.get_by(Object, ap_id: note_ap_id)
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
