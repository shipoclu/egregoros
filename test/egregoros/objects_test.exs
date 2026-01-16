defmodule Egregoros.ObjectsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users

  @note_attrs %{
    ap_id: "https://example.com/objects/1",
    type: "Note",
    actor: "https://example.com/users/alice",
    object: nil,
    data: %{"type" => "Note", "content" => "Hello from Redux"},
    published: ~U[2025-01-01 00:00:00Z],
    local: true
  }

  @like_attrs %{
    ap_id: "https://example.com/activities/like/1",
    type: "Like",
    actor: "https://example.com/users/alice",
    object: "https://example.com/objects/1",
    data: %{"type" => "Like", "object" => "https://example.com/objects/1"},
    published: ~U[2025-01-01 00:00:01Z],
    local: false
  }

  test "create_object stores jsonb data" do
    assert {:ok, %Object{} = object} = Objects.create_object(@note_attrs)
    assert object.ap_id == @note_attrs.ap_id
    assert object.data["content"] == "Hello from Redux"
  end

  test "get_by_ap_id returns stored object" do
    assert {:ok, %Object{} = object} = Objects.create_object(@note_attrs)
    assert %Object{id: id} = Objects.get_by_ap_id(@note_attrs.ap_id)
    assert id == object.id
  end

  test "get_by_ap_id returns nil for nil" do
    assert Objects.get_by_ap_id(nil) == nil
  end

  test "get returns nil for non-integer ids" do
    assert Objects.get("nope") == nil
  end

  test "ap_id is unique" do
    assert {:ok, %Object{}} = Objects.create_object(@note_attrs)
    assert {:error, changeset} = Objects.create_object(@note_attrs)
    assert "has already been taken" in errors_on(changeset).ap_id
  end

  test "upsert_object returns existing record" do
    assert {:ok, %Object{id: id}} = Objects.upsert_object(@note_attrs)
    assert {:ok, %Object{id: id_again}} = Objects.upsert_object(@note_attrs)
    assert id == id_again
  end

  test "list_notes returns only notes" do
    assert {:ok, %Object{}} = Objects.create_object(@note_attrs)
    assert {:ok, %Object{}} = Objects.create_object(@like_attrs)

    notes = Objects.list_notes()
    assert Enum.all?(notes, &(&1.type == "Note"))
  end

  test "list_public_statuses excludes unlisted statuses" do
    public = "https://www.w3.org/ns/activitystreams#Public"
    followers = "https://remote.example/users/alice/followers"

    assert {:ok, %Object{} = listed} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/listed-1",
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/listed-1",
                 "type" => "Note",
                 "actor" => "https://remote.example/users/alice",
                 "to" => [public],
                 "cc" => [],
                 "content" => "Listed"
               }
             })

    assert {:ok, %Object{} = unlisted} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/unlisted-1",
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/unlisted-1",
                 "type" => "Note",
                 "actor" => "https://remote.example/users/alice",
                 "to" => [followers],
                 "cc" => [public],
                 "content" => "Unlisted"
               }
             })

    statuses = Objects.list_public_statuses()
    assert Enum.any?(statuses, &(&1.id == listed.id))
    refute Enum.any?(statuses, &(&1.id == unlisted.id))
  end

  test "get_by_type_actor_object returns the latest matching object without raising" do
    like_1 = Map.put(@like_attrs, :ap_id, "https://example.com/activities/like/latest/1")
    like_2 = Map.put(@like_attrs, :ap_id, "https://example.com/activities/like/latest/2")

    assert {:ok, %Object{} = obj_1} = Objects.create_object(like_1)
    assert {:ok, %Object{} = obj_2} = Objects.create_object(like_2)

    assert %Object{} =
             latest = Objects.get_by_type_actor_object("Like", obj_1.actor, obj_1.object)

    assert latest.id == obj_2.id
  end

  test "delete_all_notes clears notes" do
    assert {:ok, %Object{}} = Objects.create_object(@note_attrs)
    Objects.delete_all_notes()
    assert [] == Objects.list_notes()
  end

  test "list_home_notes returns own notes and notes from followed actors" do
    {:ok, alice} = Users.create_local_user("alice")

    bob_ap_id = "https://remote.example/users/bob"
    carol_ap_id = "https://remote.example/users/carol"

    {:ok, follow_object} =
      Pipeline.ingest(
        %{
          "id" => "https://local.example/activities/follow/1",
          "type" => "Follow",
          "actor" => alice.ap_id,
          "object" => bob_ap_id
        },
        local: true
      )

    assert {:ok, _} =
             Pipeline.ingest(
               %{
                 "id" => "https://remote.example/activities/accept/1",
                 "type" => "Accept",
                 "actor" => bob_ap_id,
                 "object" => follow_object.data
               },
               local: false
             )

    assert {:ok, %Object{}} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/bob-1",
               type: "Note",
               actor: bob_ap_id,
               object: nil,
               data: %{
                 "id" => "https://remote.example/objects/bob-1",
                 "type" => "Note",
                 "actor" => bob_ap_id,
                 "to" => [bob_ap_id <> "/followers"],
                 "cc" => [],
                 "content" => "hello"
               },
               local: false
             })

    assert {:ok, %Object{}} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/carol-1",
               type: "Note",
               actor: carol_ap_id,
               object: nil,
               data: %{
                 "id" => "https://remote.example/objects/carol-1",
                 "type" => "Note",
                 "actor" => carol_ap_id,
                 "content" => "hello"
               },
               local: false
             })

    assert {:ok, %Object{}} =
             Objects.create_object(%{
               ap_id: "https://local.example/objects/alice-1",
               type: "Note",
               actor: alice.ap_id,
               object: nil,
               data: %{
                 "id" => "https://local.example/objects/alice-1",
                 "type" => "Note",
                 "actor" => alice.ap_id,
                 "content" => "hello"
               },
               local: true
             })

    notes = Objects.list_home_notes(alice.ap_id)
    assert Enum.any?(notes, &(&1.actor == alice.ap_id))
    assert Enum.any?(notes, &(&1.actor == bob_ap_id))
    refute Enum.any?(notes, &(&1.actor == carol_ap_id))
  end

  test "list_home_notes includes direct messages addressed to the user" do
    {:ok, bob} = Users.create_local_user("bob")
    dm_ap_id = "https://remote.example/objects/dm-1"

    assert {:ok, %Object{} = dm} =
             Objects.create_object(%{
               ap_id: dm_ap_id,
               type: "Note",
               actor: "https://remote.example/users/carol",
               object: nil,
               local: false,
               data: %{
                 "id" => dm_ap_id,
                 "type" => "Note",
                 "actor" => "https://remote.example/users/carol",
                 "to" => [bob.ap_id],
                 "cc" => [],
                 "content" => "secret"
               }
             })

    assert Enum.any?(Objects.list_home_notes(bob.ap_id), &(&1.id == dm.id))
  end

  test "list_home_notes includes direct messages addressed via bto/bcc/audience" do
    {:ok, bob} = Users.create_local_user("bob")

    assert {:ok, %Object{} = dm_bcc} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/dm-bcc-1",
               type: "Note",
               actor: "https://remote.example/users/carol",
               object: nil,
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/dm-bcc-1",
                 "type" => "Note",
                 "actor" => "https://remote.example/users/carol",
                 "to" => [],
                 "cc" => [],
                 "bcc" => [bob.ap_id],
                 "content" => "secret"
               }
             })

    assert {:ok, %Object{} = dm_audience} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/dm-audience-1",
               type: "Note",
               actor: "https://remote.example/users/carol",
               object: nil,
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/dm-audience-1",
                 "type" => "Note",
                 "actor" => "https://remote.example/users/carol",
                 "to" => [],
                 "cc" => [],
                 "audience" => [bob.ap_id],
                 "content" => "secret"
               }
             })

    notes = Objects.list_home_notes(bob.ap_id)
    assert Enum.any?(notes, &(&1.id == dm_bcc.id))
    assert Enum.any?(notes, &(&1.id == dm_audience.id))
  end

  test "list_home_statuses includes direct messages addressed to the user" do
    {:ok, bob} = Users.create_local_user("bob")
    dm_ap_id = "https://remote.example/objects/dm-2"

    assert {:ok, %Object{} = dm} =
             Objects.create_object(%{
               ap_id: dm_ap_id,
               type: "Note",
               actor: "https://remote.example/users/carol",
               object: nil,
               local: false,
               data: %{
                 "id" => dm_ap_id,
                 "type" => "Note",
                 "actor" => "https://remote.example/users/carol",
                 "to" => [bob.ap_id],
                 "cc" => [],
                 "content" => "secret"
               }
             })

    assert Enum.any?(Objects.list_home_statuses(bob.ap_id), &(&1.id == dm.id))
  end

  test "visible_to?/2 treats bto/bcc/audience as recipients" do
    {:ok, bob} = Users.create_local_user("bob")

    assert {:ok, %Object{} = dm} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/dm-recipient-1",
               type: "Note",
               actor: "https://remote.example/users/carol",
               object: nil,
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/dm-recipient-1",
                 "type" => "Note",
                 "actor" => "https://remote.example/users/carol",
                 "to" => [],
                 "cc" => [],
                 "bto" => [bob.ap_id],
                 "content" => "secret"
               }
             })

    assert Objects.visible_to?(dm, bob)
  end

  test "search_notes finds notes by content or summary" do
    public = "https://www.w3.org/ns/activitystreams#Public"

    assert {:ok, %Object{} = content_note} =
             Objects.create_object(%{
               ap_id: "https://local.example/objects/search-1",
               type: "Note",
               actor: "https://local.example/users/alice",
               object: nil,
               data: %{
                 "id" => "https://local.example/objects/search-1",
                 "type" => "Note",
                 "actor" => "https://local.example/users/alice",
                 "to" => [public],
                 "cc" => [],
                 "content" => "Hello world"
               },
               local: true
             })

    assert {:ok, %Object{} = summary_note} =
             Objects.create_object(%{
               ap_id: "https://local.example/objects/search-2",
               type: "Note",
               actor: "https://local.example/users/alice",
               object: nil,
               data: %{
                 "id" => "https://local.example/objects/search-2",
                 "type" => "Note",
                 "actor" => "https://local.example/users/alice",
                 "to" => [public],
                 "cc" => [],
                 "content" => "Something else",
                 "summary" => "hello from summary"
               },
               local: true
             })

    assert {:ok, %Object{} = audience_note} =
             Objects.create_object(%{
               ap_id: "https://local.example/objects/search-audience-1",
               type: "Note",
               actor: "https://local.example/users/alice",
               object: nil,
               data: %{
                 "id" => "https://local.example/objects/search-audience-1",
                 "type" => "Note",
                 "actor" => "https://local.example/users/alice",
                 "to" => [],
                 "cc" => [],
                 "audience" => [public],
                 "content" => "hello from audience"
               },
               local: true
             })

    assert {:ok, %Object{}} =
             Objects.create_object(%{
               ap_id: "https://local.example/objects/search-3",
               type: "Note",
               actor: "https://local.example/users/alice",
               object: nil,
               data: %{
                 "id" => "https://local.example/objects/search-3",
                 "type" => "Note",
                 "actor" => "https://local.example/users/alice",
                 "to" => [public],
                 "cc" => [],
                 "content" => "No match here"
               },
               local: true
             })

    assert {:ok, %Object{}} =
             Objects.create_object(%{
               ap_id: "https://local.example/activities/like/search-1",
               type: "Like",
               actor: "https://local.example/users/alice",
               object: "https://local.example/objects/search-1",
               data: %{
                 "id" => "https://local.example/activities/like/search-1",
                 "type" => "Like",
                 "content" => "hello from like"
               },
               local: true
             })

    results = Objects.search_notes("hello", limit: 10)

    assert Enum.all?(results, &(&1.type == "Note"))
    assert Enum.any?(results, &(&1.id == content_note.id))
    assert Enum.any?(results, &(&1.id == summary_note.id))
    assert Enum.any?(results, &(&1.id == audience_note.id))
  end

  test "search_notes ignores blank queries" do
    assert [] == Objects.search_notes(" ")
  end

  test "upsert_object/2 can replace existing records when asked" do
    ap_id = "https://example.com/objects/replace-1"

    assert {:ok, %Object{} = object} =
             Objects.create_object(%{
               ap_id: ap_id,
               type: "Note",
               data: %{"type" => "Note", "content" => "old"}
             })

    assert {:ok, %Object{} = replaced} =
             Objects.upsert_object(%{ap_id: ap_id, type: "Note", data: %{"content" => "new"}},
               conflict: :replace
             )

    assert replaced.id == object.id
    assert replaced.data["content"] == "new"
  end

  test "upsert_object/2 refuses to replace when the type mismatches" do
    ap_id = "https://example.com/objects/replace-2"

    assert {:ok, %Object{} = object} =
             Objects.create_object(%{
               ap_id: ap_id,
               type: "Note",
               data: %{"type" => "Note", "content" => "old"}
             })

    assert {:error, %Ecto.Changeset{}} =
             Objects.upsert_object(%{ap_id: ap_id, type: "Like", data: %{"type" => "Like"}},
               conflict: :replace
             )

    assert Objects.get(object.id).type == "Note"
  end

  test "upsert_object/2 ignores unknown conflict modes and returns the existing record" do
    ap_id = "https://example.com/objects/replace-3"

    assert {:ok, %Object{} = object} =
             Objects.create_object(%{
               ap_id: ap_id,
               type: "Note",
               data: %{"type" => "Note", "content" => "old"}
             })

    assert {:ok, %Object{} = returned} =
             Objects.upsert_object(%{ap_id: ap_id, type: "Note", data: %{"content" => "new"}},
               conflict: :unknown
             )

    assert returned.id == object.id
    assert Objects.get(object.id).data["content"] == "old"
  end

  test "upsert_object/2 falls back to default options for invalid opts" do
    assert {:ok, %Object{} = object} = Objects.upsert_object(@note_attrs, :not_a_list)
    assert object.ap_id == @note_attrs.ap_id
  end

  test "list_by_ap_ids filters blanks and returns matching objects" do
    assert {:ok, %Object{} = one} = Objects.create_object(@note_attrs)

    assert {:ok, %Object{} = two} =
             Objects.create_object(%{
               ap_id: "https://example.com/objects/2",
               type: "Note",
               actor: "https://example.com/users/alice",
               data: %{"type" => "Note", "content" => "two"}
             })

    results =
      Objects.list_by_ap_ids([
        nil,
        "",
        "   ",
        @note_attrs.ap_id,
        "  https://example.com/objects/2  ",
        "https://example.com/objects/missing"
      ])

    assert Enum.map(results, & &1.id) |> Enum.sort() == Enum.sort([one.id, two.id])
  end

  test "list_public_notes only returns notes that are publicly listed" do
    public = "https://www.w3.org/ns/activitystreams#Public"
    followers = "https://remote.example/users/alice/followers"

    assert {:ok, %Object{} = listed} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/public-listed-1",
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/public-listed-1",
                 "type" => "Note",
                 "actor" => "https://remote.example/users/alice",
                 "to" => [public],
                 "cc" => [],
                 "content" => "Listed"
               }
             })

    assert {:ok, %Object{} = unlisted} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/public-unlisted-1",
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/public-unlisted-1",
                 "type" => "Note",
                 "actor" => "https://remote.example/users/alice",
                 "to" => [followers],
                 "cc" => [public],
                 "content" => "Unlisted"
               }
             })

    assert Enum.any?(Objects.list_public_notes(), &(&1.id == listed.id))
    refute Enum.any?(Objects.list_public_notes(10), &(&1.id == unlisted.id))
  end

  test "list_notes_by_hashtag reads ActivityPub tag data instead of parsing text" do
    public = "https://www.w3.org/ns/activitystreams#Public"

    assert {:ok, %Object{} = with_tag} =
             Objects.create_object(%{
               ap_id: "https://local.example/objects/tagged-1",
               type: "Note",
               actor: "https://local.example/users/alice",
               local: true,
               data: %{
                 "id" => "https://local.example/objects/tagged-1",
                 "type" => "Note",
                 "actor" => "https://local.example/users/alice",
                 "to" => [public],
                 "cc" => [],
                 "content" => "not #parsed",
                 "tag" => [%{"type" => "Hashtag", "name" => "#elixir"}]
               }
             })

    assert {:ok, %Object{} = without_tag} =
             Objects.create_object(%{
               ap_id: "https://local.example/objects/not-tagged-1",
               type: "Note",
               actor: "https://local.example/users/alice",
               local: true,
               data: %{
                 "id" => "https://local.example/objects/not-tagged-1",
                 "type" => "Note",
                 "actor" => "https://local.example/users/alice",
                 "to" => [public],
                 "cc" => [],
                 "content" => "#elixir but no tag field"
               }
             })

    assert Enum.any?(Objects.list_notes_by_hashtag("elixir"), &(&1.id == with_tag.id))
    refute Enum.any?(Objects.list_notes_by_hashtag("elixir"), &(&1.id == without_tag.id))
    assert Objects.list_notes_by_hashtag("   ") == []
  end

  test "list_notes_by_hashtag returns an empty list for invalid input types" do
    assert Objects.list_notes_by_hashtag(nil) == []
    assert Objects.list_notes_by_hashtag(123) == []
  end

  test "list_public_statuses_by_hashtag returns notes and announces matching the hashtag" do
    public = "https://www.w3.org/ns/activitystreams#Public"

    note_ap_id = "https://remote.example/objects/tagged-announce-#{Ecto.UUID.generate()}"
    other_ap_id = "https://remote.example/objects/tagged-other-#{Ecto.UUID.generate()}"

    assert {:ok, %Object{} = note} =
             Objects.create_object(%{
               ap_id: note_ap_id,
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => note_ap_id,
                 "type" => "Note",
                 "actor" => "https://remote.example/users/alice",
                 "to" => [public],
                 "cc" => [],
                 "content" => "Hello",
                 "tag" => [%{"type" => "Hashtag", "name" => "#elixir"}]
               }
             })

    assert {:ok, %Object{} = other_note} =
             Objects.create_object(%{
               ap_id: other_ap_id,
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => other_ap_id,
                 "type" => "Note",
                 "actor" => "https://remote.example/users/alice",
                 "to" => [public],
                 "cc" => [],
                 "content" => "Hello",
                 "tag" => [%{"type" => "Hashtag", "name" => "#other"}]
               }
             })

    assert {:ok, %Object{} = announce} =
             Objects.create_object(%{
               ap_id:
                 "https://remote.example/activities/announce-hashtag-#{Ecto.UUID.generate()}",
               type: "Announce",
               actor: "https://remote.example/users/bob",
               object: note.ap_id,
               local: false,
               data: %{
                 "id" => "https://remote.example/activities/announce-hashtag",
                 "type" => "Announce",
                 "actor" => "https://remote.example/users/bob",
                 "object" => note.ap_id,
                 "to" => [public],
                 "cc" => []
               }
             })

    results = Objects.list_public_statuses_by_hashtag("  #ELIXIR ")

    assert Enum.any?(results, &(&1.id == note.id))
    assert Enum.any?(results, &(&1.id == announce.id))
    refute Enum.any?(results, &(&1.id == other_note.id))
  end

  test "list_public_statuses_by_hashtag returns [] for blank or invalid inputs" do
    assert Objects.list_public_statuses_by_hashtag("   ") == []
    assert Objects.list_public_statuses_by_hashtag(nil) == []
  end

  test "count_emoji_reacts counts reactions per emoji and object" do
    object_ap_id = "https://remote.example/objects/react-target-#{Ecto.UUID.generate()}"
    actor = "https://remote.example/users/alice"

    for emoji <- ["🔥", "🔥", "👍"] do
      {:ok, _} =
        Objects.create_object(%{
          ap_id: "https://remote.example/activities/react-#{Ecto.UUID.generate()}",
          type: "EmojiReact",
          actor: actor,
          object: object_ap_id,
          local: false,
          data: %{
            "id" => "https://remote.example/activities/react",
            "type" => "EmojiReact",
            "actor" => actor,
            "object" => object_ap_id,
            "content" => emoji
          }
        })
    end

    assert Objects.count_emoji_reacts(object_ap_id, "🔥") == 2
    assert Objects.count_emoji_reacts(object_ap_id, "👍") == 1
  end

  test "list_follows_to and list_follows_by_actor return follow objects" do
    actor = "https://remote.example/users/alice"
    object = "https://remote.example/users/bob"

    assert {:ok, %Object{} = follow} =
             Objects.create_object(%{
               ap_id: "https://remote.example/activities/follow-#{Ecto.UUID.generate()}",
               type: "Follow",
               actor: actor,
               object: object,
               local: false,
               data: %{"type" => "Follow", "actor" => actor, "object" => object}
             })

    assert Enum.any?(Objects.list_follows_to(object), &(&1.id == follow.id))
    assert Enum.any?(Objects.list_follows_by_actor(actor), &(&1.id == follow.id))
  end

  test "list_home_notes accepts an integer limit argument" do
    {:ok, alice} = Users.create_local_user("alice")

    for idx <- 1..3 do
      assert {:ok, _} =
               Pipeline.ingest(
                 %{
                   "id" =>
                     "https://local.example/objects/home-limit-#{idx}-#{Ecto.UUID.generate()}",
                   "type" => "Note",
                   "actor" => alice.ap_id,
                   "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                   "cc" => [],
                   "content" => "Post #{idx}"
                 },
                 local: true
               )
    end

    assert length(Objects.list_home_notes(alice.ap_id, 1)) == 1
  end

  test "list_notes_by_actor supports default and integer limits" do
    actor = "https://remote.example/users/alice"
    public = "https://www.w3.org/ns/activitystreams#Public"

    for idx <- 1..25 do
      assert {:ok, _} =
               Objects.create_object(%{
                 ap_id: "https://remote.example/objects/by-actor-#{idx}-#{Ecto.UUID.generate()}",
                 type: "Note",
                 actor: actor,
                 local: false,
                 data: %{
                   "id" => "https://remote.example/objects/by-actor-#{idx}",
                   "type" => "Note",
                   "actor" => actor,
                   "to" => [public],
                   "cc" => [],
                   "content" => "Post #{idx}"
                 }
               })
    end

    assert length(Objects.list_notes_by_actor(actor)) == 20
    assert length(Objects.list_notes_by_actor(actor, 5)) == 5
  end

  test "list_visible_notes_by_actor respects profile visibility rules" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    public = "https://www.w3.org/ns/activitystreams#Public"
    followers = alice.ap_id <> "/followers"

    {:ok, public_note} =
      Objects.create_object(%{
        ap_id: "https://local.example/objects/profile-public-#{Ecto.UUID.generate()}",
        type: "Note",
        actor: alice.ap_id,
        local: true,
        data: %{
          "id" => "https://local.example/objects/profile-public",
          "type" => "Note",
          "to" => [public],
          "cc" => []
        }
      })

    {:ok, followers_note} =
      Objects.create_object(%{
        ap_id: "https://local.example/objects/profile-followers-#{Ecto.UUID.generate()}",
        type: "Note",
        actor: alice.ap_id,
        local: true,
        data: %{
          "id" => "https://local.example/objects/profile-followers",
          "type" => "Note",
          "to" => [followers],
          "cc" => []
        }
      })

    {:ok, direct_note} =
      Objects.create_object(%{
        ap_id: "https://local.example/objects/profile-direct-#{Ecto.UUID.generate()}",
        type: "Note",
        actor: alice.ap_id,
        local: true,
        data: %{
          "id" => "https://local.example/objects/profile-direct",
          "type" => "Note",
          "to" => [bob.ap_id],
          "cc" => []
        }
      })

    assert Enum.any?(
             Objects.list_visible_notes_by_actor(alice.ap_id, nil),
             &(&1.id == public_note.id)
           )

    refute Enum.any?(
             Objects.list_visible_notes_by_actor(alice.ap_id, nil),
             &(&1.id == followers_note.id)
           )

    refute Enum.any?(
             Objects.list_visible_notes_by_actor(alice.ap_id, nil),
             &(&1.id == direct_note.id)
           )

    assert Enum.any?(
             Objects.list_visible_notes_by_actor(alice.ap_id, bob),
             &(&1.id == public_note.id)
           )

    refute Enum.any?(
             Objects.list_visible_notes_by_actor(alice.ap_id, bob),
             &(&1.id == followers_note.id)
           )

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: bob.ap_id,
               object: alice.ap_id
             })

    follower_view = Objects.list_visible_notes_by_actor(alice.ap_id, bob)
    assert Enum.any?(follower_view, &(&1.id == followers_note.id))
    refute Enum.any?(follower_view, &(&1.id == direct_note.id))

    self_view = Objects.list_visible_notes_by_actor(alice.ap_id, alice)
    assert Enum.any?(self_view, &(&1.id == direct_note.id))
  end

  test "list_visible_statuses_by_actor includes announces when the object exists" do
    {:ok, alice} = Users.create_local_user("alice")
    public = "https://www.w3.org/ns/activitystreams#Public"

    {:ok, note} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/status-#{Ecto.UUID.generate()}",
        type: "Note",
        actor: alice.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/objects/status",
          "type" => "Note",
          "to" => [public],
          "cc" => []
        }
      })

    {:ok, announce} =
      Objects.create_object(%{
        ap_id: "https://remote.example/activities/announce-#{Ecto.UUID.generate()}",
        type: "Announce",
        actor: alice.ap_id,
        object: note.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/activities/announce",
          "type" => "Announce",
          "object" => note.ap_id,
          "to" => [public],
          "cc" => []
        }
      })

    statuses = Objects.list_visible_statuses_by_actor(alice.ap_id, nil, limit: 10)
    assert Enum.any?(statuses, &(&1.id == note.id))
    assert Enum.any?(statuses, &(&1.id == announce.id))
  end

  test "list_visible_notes_by_actor and list_visible_statuses_by_actor return [] for invalid inputs" do
    assert Objects.list_visible_notes_by_actor(nil, nil) == []
    assert Objects.list_visible_statuses_by_actor(nil, nil) == []
  end

  test "normalize_limit falls back to 20 for invalid values" do
    actor = "https://remote.example/users/alice"
    public = "https://www.w3.org/ns/activitystreams#Public"

    for idx <- 1..25 do
      assert {:ok, _} =
               Objects.create_object(%{
                 ap_id:
                   "https://remote.example/objects/limit-default-#{idx}-#{Ecto.UUID.generate()}",
                 type: "Note",
                 actor: actor,
                 local: false,
                 data: %{
                   "id" => "https://remote.example/objects/limit-default-#{idx}",
                   "type" => "Note",
                   "actor" => actor,
                   "to" => [public],
                   "cc" => [],
                   "content" => "Post #{idx}"
                 }
               })
    end

    assert length(Objects.list_notes(limit: "nope")) == 20
  end

  test "list_public_statuses_by_actor and list_statuses_by_actor support paging options" do
    actor = "https://remote.example/users/paging"
    public = "https://www.w3.org/ns/activitystreams#Public"

    created =
      for idx <- 1..3 do
        {:ok, object} =
          Objects.create_object(%{
            ap_id: "https://remote.example/objects/paging-#{idx}-#{Ecto.UUID.generate()}",
            type: "Note",
            actor: actor,
            local: false,
            data: %{
              "id" => "https://remote.example/objects/paging-#{idx}",
              "type" => "Note",
              "to" => [public],
              "cc" => []
            }
          })

        object
      end

    [newest, middle | _rest] = Enum.sort_by(created, & &1.id, :desc)

    assert Enum.all?(
             Objects.list_statuses_by_actor(actor, since_id: middle.id),
             &(&1.id > middle.id)
           )

    assert Enum.all?(
             Objects.list_public_statuses_by_actor(actor, max_id: newest.id),
             &(&1.id < newest.id)
           )
  end

  test "list_public_statuses supports filtering to posts with media including reblogs" do
    public = "https://www.w3.org/ns/activitystreams#Public"

    assert {:ok, %Object{} = media_note} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/media-note-1",
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/media-note-1",
                 "type" => "Note",
                 "actor" => "https://remote.example/users/alice",
                 "to" => [public],
                 "cc" => [],
                 "content" => "With media",
                 "attachment" => [
                   %{
                     "mediaType" => "image/png",
                     "url" => [%{"href" => "https://cdn.example/x.png"}]
                   }
                 ]
               }
             })

    assert {:ok, %Object{} = no_media_note} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/no-media-note-1",
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/no-media-note-1",
                 "type" => "Note",
                 "actor" => "https://remote.example/users/alice",
                 "to" => [public],
                 "cc" => [],
                 "content" => "No media"
               }
             })

    assert {:ok, %Object{} = announce} =
             Objects.create_object(%{
               ap_id: "https://remote.example/activities/announce-media-1",
               type: "Announce",
               actor: "https://remote.example/users/bob",
               object: media_note.ap_id,
               local: false,
               data: %{
                 "id" => "https://remote.example/activities/announce-media-1",
                 "type" => "Announce",
                 "actor" => "https://remote.example/users/bob",
                 "object" => media_note.ap_id,
                 "to" => [public],
                 "cc" => []
               }
             })

    media_only = Objects.list_public_statuses(only_media: true)

    assert Enum.any?(media_only, &(&1.id == media_note.id))
    refute Enum.any?(media_only, &(&1.id == no_media_note.id))
    assert Enum.any?(media_only, &(&1.id == announce.id))
  end

  test "visible_to?/2 treats recipient maps as recipients and supports followers-only visibility" do
    {:ok, viewer} = Users.create_local_user("viewer")

    actor_ap_id = "https://remote.example/users/author"

    assert {:ok, %Object{} = dm_string} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/dm-recipient-map-1",
               type: "Note",
               actor: actor_ap_id,
               object: nil,
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/dm-recipient-map-1",
                 "type" => "Note",
                 "actor" => actor_ap_id,
                 "to" => [%{"id" => viewer.ap_id}],
                 "cc" => [],
                 "content" => "secret"
               }
             })

    assert Objects.visible_to?(dm_string, viewer.ap_id)

    assert {:ok, %Object{} = dm_atom} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/dm-recipient-map-2",
               type: "Note",
               actor: actor_ap_id,
               object: nil,
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/dm-recipient-map-2",
                 "type" => "Note",
                 "actor" => actor_ap_id,
                 "to" => [%{id: viewer.ap_id}],
                 "cc" => [],
                 "content" => "secret"
               }
             })

    assert Objects.visible_to?(dm_atom, viewer)

    followers_collection = actor_ap_id <> "/followers"

    assert {:ok, %Object{} = followers_only} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/followers-only-1",
               type: "Note",
               actor: actor_ap_id,
               object: nil,
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/followers-only-1",
                 "type" => "Note",
                 "actor" => actor_ap_id,
                 "to" => [followers_collection],
                 "cc" => [],
                 "content" => "followers only"
               }
             })

    refute Objects.visible_to?(followers_only, viewer)

    {:ok, follow_object} =
      Pipeline.ingest(
        %{
          "id" => "https://local.example/activities/follow/2",
          "type" => "Follow",
          "actor" => viewer.ap_id,
          "object" => actor_ap_id
        },
        local: true
      )

    assert {:ok, _} =
             Pipeline.ingest(
               %{
                 "id" => "https://remote.example/activities/accept/2",
                 "type" => "Accept",
                 "actor" => actor_ap_id,
                 "object" => follow_object.data
               },
               local: false
             )

    assert Objects.visible_to?(followers_only, viewer.ap_id)
  end

  test "thread helpers handle map-shaped inReplyTo and list replies with default opts" do
    root_ap_id = "https://remote.example/objects/thread-root-1"

    assert {:ok, %Object{} = root} =
             Objects.create_object(%{
               ap_id: root_ap_id,
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => root_ap_id,
                 "type" => "Note",
                 "actor" => "https://remote.example/users/alice",
                 "content" => "Root"
               }
             })

    assert {:ok, %Object{} = reply} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/thread-reply-1",
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/thread-reply-1",
                 "type" => "Note",
                 "actor" => "https://remote.example/users/alice",
                 "inReplyTo" => %{"id" => root.ap_id},
                 "content" => "Reply"
               }
             })

    assert Objects.thread_ancestors(reply, 10) |> Enum.map(& &1.id) == [root.id]

    assert {:ok, %Object{} = reply_string} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/thread-reply-2",
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/thread-reply-2",
                 "type" => "Note",
                 "actor" => "https://remote.example/users/alice",
                 "inReplyTo" => root.ap_id,
                 "content" => "Reply 2"
               }
             })

    replies = Objects.list_replies_to(root.ap_id)
    assert Enum.any?(replies, &(&1.id == reply.id))
    assert Enum.any?(replies, &(&1.id == reply_string.id))
    assert Objects.thread_ancestors(nil, 10) == []
    assert Objects.thread_descendants(nil, 10) == []
  end

  test "creates and counts create activities by actor" do
    actor = "https://example.com/users/alice"

    assert {:ok, %Object{} = create} =
             Objects.create_object(%{
               ap_id: "https://example.com/activities/create/1",
               type: "Create",
               actor: actor,
               local: true,
               data: %{
                 "id" => "https://example.com/activities/create/1",
                 "type" => "Create",
                 "actor" => actor,
                 "to" => ["https://www.w3.org/ns/activitystreams#Public"]
               }
             })

    assert Enum.any?(Objects.list_creates_by_actor(actor), &(&1.id == create.id))
    assert Enum.any?(Objects.list_public_creates_by_actor(actor), &(&1.id == create.id))
    assert Objects.count_creates_by_actor(actor) == 1
    assert Objects.count_public_creates_by_actor(actor) == 1
    assert Objects.search_notes(:not_a_binary, limit: 5) == []
    refute Objects.publicly_visible?(:not_an_object)
    refute Objects.publicly_listed?(:not_an_object)
  end
end
