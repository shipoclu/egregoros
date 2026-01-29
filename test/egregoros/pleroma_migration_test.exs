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

  test "import_users/1 batches inserts to avoid postgres parameter limit" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    users =
      for _i <- 1..5000 do
        nickname = "u#{System.unique_integer([:positive])}"
        ap_id = "https://example.com/users/#{nickname}"

        %{
          id: FlakeId.get(),
          nickname: nickname,
          domain: nil,
          ap_id: ap_id,
          inbox: ap_id <> "/inbox",
          outbox: ap_id <> "/outbox",
          public_key: "PUB",
          private_key: nil,
          local: true,
          admin: false,
          locked: false,
          email: nil,
          password_hash: nil,
          name: nil,
          bio: nil,
          avatar_url: nil,
          banner_url: nil,
          emojis: [],
          moved_to_ap_id: nil,
          also_known_as: [],
          remote_followers_count: nil,
          remote_following_count: nil,
          remote_counts_checked_at: nil,
          notifications_last_seen_id: nil,
          inserted_at: now,
          updated_at: now
        }
      end

    assert %{inserted: 5000, attempted: 5000} = PleromaMigration.import_users(users)
  end

  test "import_statuses/1 batches inserts to avoid postgres parameter limit" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    statuses =
      for _i <- 1..6000 do
        status_id = FlakeId.get()
        note_ap_id = "https://example.com/objects/#{Ecto.UUID.generate()}"
        activity_ap_id = "https://example.com/activities/#{Ecto.UUID.generate()}"
        actor_ap_id = "https://example.com/users/alice"

        note = %{
          "id" => note_ap_id,
          "type" => "Note",
          "actor" => actor_ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [],
          "content" => "bulk import"
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

        %{
          activity_id: status_id,
          activity: create,
          object: note,
          local: true,
          inserted_at: now,
          updated_at: now
        }
      end

    assert %{inserted: 12_000, attempted: 6000} = PleromaMigration.import_statuses(statuses)
  end

  test "import_statuses/1 normalizes published datetime precision" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    status_id = FlakeId.get()
    note_ap_id = "https://example.com/objects/#{Ecto.UUID.generate()}"
    activity_ap_id = "https://example.com/activities/#{Ecto.UUID.generate()}"
    actor_ap_id = "https://example.com/users/alice"

    note = %{
      "id" => note_ap_id,
      "type" => "Note",
      "actor" => actor_ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "content" => "datetime precision test"
    }

    create = %{
      "id" => activity_ap_id,
      "type" => "Create",
      "actor" => actor_ap_id,
      "to" => note["to"],
      "cc" => note["cc"],
      "object" => note_ap_id,
      # No fractional seconds -> DateTime.from_iso8601 returns {0, 0} microseconds.
      "published" => "2026-01-16T16:05:38Z"
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
  end

  test "import_statuses/1 tolerates Create activities without id" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    status_id = FlakeId.get()
    note_ap_id = "https://example.com/objects/#{Ecto.UUID.generate()}"
    actor_ap_id = "https://example.com/users/alice"

    note = %{
      "id" => note_ap_id,
      "type" => "Note",
      "actor" => actor_ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "content" => "missing create id"
    }

    create = %{
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

    assert %{inserted: 1, attempted: 1} = PleromaMigration.import_statuses(statuses)

    assert %Object{id: ^status_id, type: "Note"} = Repo.get_by(Object, ap_id: note_ap_id)
    refute Repo.get_by(Object, type: "Create", object: note_ap_id)
  end

  test "import_statuses/1 normalizes naive timestamps to utc_datetime_usec" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    inserted_at = ~N[2026-01-01 00:00:00]
    updated_at = ~N[2026-01-01 00:00:01]

    status_id = FlakeId.get()
    note_ap_id = "https://example.com/objects/#{Ecto.UUID.generate()}"
    activity_ap_id = "https://example.com/activities/#{Ecto.UUID.generate()}"
    actor_ap_id = "https://example.com/users/alice"

    note = %{
      "id" => note_ap_id,
      "type" => "Note",
      "actor" => actor_ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "content" => "naive timestamp test"
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
        inserted_at: inserted_at,
        updated_at: updated_at
      }
    ]

    assert %{inserted: 2, attempted: 1} = PleromaMigration.import_statuses(statuses)

    assert %Object{inserted_at: stored_inserted_at, updated_at: stored_updated_at} =
             Repo.get_by(Object, ap_id: note_ap_id)

    assert NaiveDateTime.truncate(DateTime.to_naive(stored_inserted_at), :second) == inserted_at
    assert NaiveDateTime.truncate(DateTime.to_naive(stored_updated_at), :second) == updated_at
    assert stored_inserted_at.microsecond == {0, 6}
    assert stored_updated_at.microsecond == {0, 6}
  end

  test "import_statuses/1 sets in_reply_to_ap_id and has_media for Note objects" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    status_id = FlakeId.get()
    note_ap_id = "https://example.com/objects/#{Ecto.UUID.generate()}"
    activity_ap_id = "https://example.com/activities/#{Ecto.UUID.generate()}"
    actor_ap_id = "https://example.com/users/alice"
    in_reply_to_ap_id = "https://example.com/objects/#{Ecto.UUID.generate()}"

    note = %{
      "id" => note_ap_id,
      "type" => "Note",
      "actor" => actor_ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "inReplyTo" => in_reply_to_ap_id,
      "attachment" => [%{"type" => "Document", "url" => "https://example.com/media/1"}],
      "content" => "reply with media"
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

    assert %Object{in_reply_to_ap_id: ^in_reply_to_ap_id, has_media: true} =
             Repo.get_by(Object, ap_id: note_ap_id)
  end

  test "import_statuses/1 imports Announce activities" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    status_id = FlakeId.get()
    announce_ap_id = "https://example.com/activities/#{Ecto.UUID.generate()}"
    actor_ap_id = "https://example.com/users/alice"
    object_ap_id = "https://example.com/objects/#{Ecto.UUID.generate()}"

    announce = %{
      "id" => announce_ap_id,
      "type" => "Announce",
      "actor" => actor_ap_id,
      "object" => object_ap_id,
      "published" => DateTime.to_iso8601(now)
    }

    statuses = [
      %{
        activity_id: status_id,
        activity: announce,
        local: true,
        inserted_at: now,
        updated_at: now
      }
    ]

    assert %{inserted: 1, attempted: 1} = PleromaMigration.import_statuses(statuses)
    assert %Object{id: ^status_id, type: "Announce"} = Repo.get_by(Object, ap_id: announce_ap_id)
  end

  test "import_users/1 returns an empty summary for invalid input" do
    assert %{inserted: 0, attempted: 0} = PleromaMigration.import_users(nil)
  end
end
