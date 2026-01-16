defmodule EgregorosWeb.ViewModels.StatusTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Activities.Note
  alias Egregoros.Interactions
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Users
  alias EgregorosWeb.ViewModels.Status

  test "decorates a note with actor details and counts" do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, note} = Pipeline.ingest(Note.build(user, "Hello world"), local: true)

    entry = Status.decorate(note, user)

    assert entry.object.id == note.id
    assert entry.actor.handle == "@alice"
    assert entry.likes_count == 0
    assert entry.reposts_count == 0
    assert entry.reactions["🔥"].count == 0
  end

  test "includes emoji reactions outside the default set when present" do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, note} = Pipeline.ingest(Note.build(user, "Hello world"), local: true)

    assert {:ok, _} = Interactions.toggle_reaction(user, note.id, "😀")

    entry = Status.decorate(note, user)

    assert entry.reactions["😀"].count == 1
    assert entry.reactions["😀"].reacted?
  end

  test "filters unsafe attachment URLs" do
    {:ok, user} = Users.create_local_user("alice")
    public = "https://www.w3.org/ns/activitystreams#Public"

    note_id = "http://localhost:4000/objects/" <> Ecto.UUID.generate()

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: note_id,
               type: "Note",
               actor: user.ap_id,
               object: nil,
               local: true,
               data: %{
                 "id" => note_id,
                 "type" => "Note",
                 "actor" => user.ap_id,
                 "to" => [public],
                 "cc" => [],
                 "content" => "<p>Hello</p>",
                 "attachment" => [
                   %{
                     "id" => "http://evil.example/media/1",
                     "type" => "Image",
                     "mediaType" => "image/png",
                     "url" => [
                       %{
                         "type" => "Link",
                         "mediaType" => "image/png",
                         "href" => "http://127.0.0.1/evil.png"
                       }
                     ],
                     "name" => "evil"
                   }
                 ]
               }
             })

    entry = Status.decorate(note, user)
    assert entry.attachments == []
  end

  test "decorates safe attachments with href, preview, and media type" do
    uniq = System.unique_integer([:positive])
    {:ok, user} = Users.create_local_user("status-attachments-#{uniq}")
    public = "https://www.w3.org/ns/activitystreams#Public"

    note_id = "http://localhost:4000/objects/" <> Ecto.UUID.generate()

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: note_id,
               type: "Note",
               actor: user.ap_id,
               object: nil,
               local: true,
               data: %{
                 "id" => note_id,
                 "type" => "Note",
                 "actor" => user.ap_id,
                 "to" => [public],
                 "cc" => [],
                 "content" => "<p>Hello</p>",
                 "attachment" => [
                   %{
                     "type" => "Image",
                     "url" => [
                       %{
                         "type" => "Link",
                         "mediaType" => "image/png",
                         "href" => "https://cdn.example/ok.png"
                       }
                     ],
                     "icon" => %{
                       "url" => [
                         %{
                           "type" => "Link",
                           "href" => "https://cdn.example/ok_thumb.png"
                         }
                       ]
                     },
                     "name" => "  ok  "
                   }
                 ]
               }
             })

    entry = Status.decorate(note, user)

    assert [
             %{
               href: "https://cdn.example/ok.png",
               preview_href: "https://cdn.example/ok_thumb.png",
               media_type: "image/png",
               description: "ok"
             }
           ] = entry.attachments
  end

  test "decorates interaction counts and flags for the current user" do
    uniq = System.unique_integer([:positive])
    {:ok, author} = Users.create_local_user("status-author-#{uniq}")
    {:ok, viewer} = Users.create_local_user("status-viewer-#{uniq}")
    {:ok, note} = Pipeline.ingest(Note.build(author, "Hello world"), local: true)

    assert {:ok, _} = Interactions.toggle_like(viewer, note.id)
    assert {:ok, _} = Interactions.toggle_repost(viewer, note.id)
    assert {:ok, :bookmarked} = Interactions.toggle_bookmark(viewer, note.id)
    assert {:ok, _} = Interactions.toggle_reaction(viewer, note.id, "🤖")

    entry = Status.decorate(note, viewer)

    assert entry.likes_count == 1
    assert entry.liked?
    assert entry.reposts_count == 1
    assert entry.reposted?
    assert entry.bookmarked?
    assert entry.reactions["🤖"].count == 1
    assert entry.reactions["🤖"].reacted?
  end

  test "includes reblogs of posts addressed to the viewer" do
    uniq = System.unique_integer([:positive])
    {:ok, author} = Users.create_local_user("status-direct-author-#{uniq}")
    {:ok, reposter} = Users.create_local_user("status-direct-reposter-#{uniq}")
    {:ok, viewer} = Users.create_local_user("status-direct-viewer-#{uniq}")

    note_id = "http://localhost:4000/objects/" <> Ecto.UUID.generate()

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: note_id,
               type: "Note",
               actor: author.ap_id,
               object: nil,
               local: true,
               data: %{
                 "id" => note_id,
                 "type" => "Note",
                 "actor" => author.ap_id,
                 "to" => [%{"id" => viewer.ap_id}],
                 "content" => "hi"
               }
             })

    announce_id = "http://localhost:4000/objects/" <> Ecto.UUID.generate()

    assert {:ok, announce} =
             Objects.create_object(%{
               ap_id: announce_id,
               type: "Announce",
               actor: reposter.ap_id,
               object: note.ap_id,
               local: true,
               data: %{
                 "id" => announce_id,
                 "type" => "Announce",
                 "actor" => reposter.ap_id,
                 "object" => note.ap_id
               }
             })

    reposter_ap_id = reposter.ap_id

    assert [
             %{
               feed_id: announce_db_id,
               object: %{ap_id: ^note_id},
               reposted_by: %{ap_id: ^reposter_ap_id}
             }
           ] = Status.decorate_many([announce], viewer)

    assert announce_db_id == announce.id
  end

  test "filters reblogs of followers-only posts unless the viewer follows the author" do
    uniq = System.unique_integer([:positive])
    {:ok, author} = Users.create_local_user("status-followers-author-#{uniq}")
    {:ok, reposter} = Users.create_local_user("status-followers-reposter-#{uniq}")
    {:ok, viewer} = Users.create_local_user("status-followers-viewer-#{uniq}")

    note_id = "http://localhost:4000/objects/" <> Ecto.UUID.generate()

    {:ok, note} =
      Objects.create_object(%{
        ap_id: note_id,
        type: "Note",
        actor: author.ap_id,
        object: nil,
        local: true,
        data: %{
          "id" => note_id,
          "type" => "Note",
          "actor" => author.ap_id,
          "to" => [author.ap_id <> "/followers"],
          "content" => "followers-only"
        }
      })

    announce_id = "http://localhost:4000/objects/" <> Ecto.UUID.generate()

    {:ok, announce} =
      Objects.create_object(%{
        ap_id: announce_id,
        type: "Announce",
        actor: reposter.ap_id,
        object: note.ap_id,
        local: true,
        data: %{
          "id" => announce_id,
          "type" => "Announce",
          "actor" => reposter.ap_id,
          "object" => note.ap_id
        }
      })

    assert Status.decorate_many([announce], viewer) == []

    assert {:ok, _follow} =
             Pipeline.ingest(
               %{
                 "id" => "https://local.example/activities/follow/#{uniq}",
                 "type" => "Follow",
                 "actor" => viewer.ap_id,
                 "object" => author.ap_id
               },
               local: true
             )

    reposter_ap_id = reposter.ap_id

    assert [
             %{
               feed_id: announce_db_id,
               object: %{ap_id: ^note_id},
               reposted_by: %{ap_id: ^reposter_ap_id}
             }
           ] = Status.decorate_many([announce], viewer)

    assert announce_db_id == announce.id
    assert reposter_ap_id == reposter.ap_id
  end

  test "filters reblogs when the announced object is missing" do
    uniq = System.unique_integer([:positive])
    {:ok, reposter} = Users.create_local_user("status-missing-reposter-#{uniq}")

    announce_id = "http://localhost:4000/objects/" <> Ecto.UUID.generate()

    assert {:ok, announce} =
             Objects.create_object(%{
               ap_id: announce_id,
               type: "Announce",
               actor: reposter.ap_id,
               object: "https://missing.example/objects/#{uniq}",
               local: true,
               data: %{
                 "id" => announce_id,
                 "type" => "Announce",
                 "actor" => reposter.ap_id,
                 "object" => "https://missing.example/objects/#{uniq}"
               }
             })

    assert Status.decorate_many([announce], reposter) == []
  end
end
