defmodule EgregorosWeb.MastodonAPI.StatusesControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Publish
  alias Egregoros.Relationships
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint

  test "POST /api/v1/statuses creates a status", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn = post(conn, "/api/v1/statuses", %{"status" => "Hello API"})

    response = json_response(conn, 200)
    assert response["content"] == "<p>Hello API</p>"
    assert response["account"]["username"] == "local"

    [object] = Objects.list_notes()
    assert object.data["content"] == "<p>Hello API</p>"
  end

  test "POST /api/v1/statuses rejects missing status param", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn = post(conn, "/api/v1/statuses", %{})
    assert response(conn, 422)
    assert Objects.list_notes() == []
  end

  test "PUT /api/v1/statuses/:id updates a status and emits an Update activity", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")
    {:ok, create} = Publish.post_note(user, "Original")

    note = Objects.get_by_ap_id(create.object)
    assert note.data["content"] == "<p>Original</p>"

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn = put(conn, "/api/v1/statuses/#{note.id}", %{"status" => "Edited"})

    response = json_response(conn, 200)
    assert response["id"] == Integer.to_string(note.id)
    assert response["content"] == "<p>Edited</p>"

    note = Objects.get(note.id)
    assert note.data["content"] == "<p>Edited</p>"

    assert Objects.get_by_type_actor_object("Update", user.ap_id, note.ap_id)
  end

  test "PUT /api/v1/statuses/:id rejects empty status", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")
    {:ok, create} = Publish.post_note(user, "Original")
    note = Objects.get_by_ap_id(create.object)

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn = put(conn, "/api/v1/statuses/#{note.id}", %{"status" => "  "})
    assert response(conn, 422)
    assert Objects.get(note.id).data["content"] == "<p>Original</p>"
  end

  test "PUT /api/v1/statuses/:id forbids updating other users' or remote statuses", %{conn: conn} do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    {:ok, create} = Publish.post_note(alice, "Owned by alice")
    note = Objects.get_by_ap_id(create.object)

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, bob} end)

    conn = put(conn, "/api/v1/statuses/#{note.id}", %{"status" => "Edited?"})
    assert response(conn, 403)

    {:ok, remote_note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/remote-edit",
          "type" => "Note",
          "actor" => alice.ap_id,
          "content" => "Remote",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => []
        },
        local: false
      )

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, alice} end)

    conn = put(conn, "/api/v1/statuses/#{remote_note.id}", %{"status" => "Edited remote?"})
    assert response(conn, 403)
  end

  test "PUT /api/v1/statuses/:id updates summary, sensitive, language, and mention links", %{
    conn: conn
  } do
    {:ok, user} = Users.create_local_user("local")
    {:ok, create} = Publish.post_note(user, "Original")
    note = Objects.get_by_ap_id(create.object)

    tags = [
      %{
        "type" => "Mention",
        "href" => "https://remote.example/users/bob",
        "name" => "@bob@remote.example"
      },
      %{
        "type" => "Mention",
        "href" => "https://remote.example/users/invalid",
        "name" => "@???"
      }
    ]

    {:ok, _} = Objects.update_object(note, %{data: Map.put(note.data, "tag", tags)})

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn =
      put(conn, "/api/v1/statuses/#{note.id}", %{
        "status" => "Hello @bob@remote.example",
        "spoiler_text" => "cw",
        "sensitive" => "true",
        "language" => "en"
      })

    response = json_response(conn, 200)

    assert response["content"] =~ "mention-link"
    assert response["content"] =~ "bob@remote.example"
    assert response["spoiler_text"] == "cw"
    assert response["sensitive"] == true
    assert response["language"] == "en"
  end

  test "GET /api/v1/statuses/:id/source returns StatusSource for the owner", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")
    {:ok, create} = Publish.post_note(user, "Hello source", spoiler_text: "cw")

    note = Objects.get_by_ap_id(create.object)

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer token")
      |> get("/api/v1/statuses/#{note.id}/source")

    response = json_response(conn, 200)
    assert response["id"] == Integer.to_string(note.id)
    assert response["text"] == "Hello source"
    assert response["spoiler_text"] == "cw"
  end

  test "GET /api/v1/statuses/:id/source returns 404 for non-owners", %{conn: conn} do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    {:ok, create} = Publish.post_note(alice, "Hello source")
    note = Objects.get_by_ap_id(create.object)

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, bob} end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer token")
      |> get("/api/v1/statuses/#{note.id}/source")

    assert response(conn, 404)
  end

  test "GET /api/v1/statuses/:id/source falls back to content when source is missing", %{
    conn: conn
  } do
    {:ok, user} = Users.create_local_user("local")

    {:ok, note} =
      Objects.create_object(%{
        ap_id: Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        type: "Note",
        actor: user.ap_id,
        local: true,
        data: %{"type" => "Note", "content" => "<p>Fallback</p>"}
      })

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer token")
      |> get("/api/v1/statuses/#{note.id}/source")

    response = json_response(conn, 200)
    assert response["text"] == "<p>Fallback</p>"
  end

  test "POST /api/v1/statuses supports replies via in_reply_to_id", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, parent} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/parent",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Parent post",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => []
        },
        local: false
      )

    conn =
      post(conn, "/api/v1/statuses", %{
        "status" => "Reply post",
        "in_reply_to_id" => Integer.to_string(parent.id)
      })

    response = json_response(conn, 200)
    assert response["content"] == "<p>Reply post</p>"
    assert response["in_reply_to_id"] == Integer.to_string(parent.id)

    [reply, _parent] = Objects.list_notes()
    assert reply.data["content"] == "<p>Reply post</p>"
    assert reply.data["inReplyTo"] == parent.ap_id
  end

  test "POST /api/v1/statuses rejects replies to statuses not visible to the user", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")
    {:ok, recipient} = Users.create_local_user("bob")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, dm} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/dm-parent",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Secret DM for bob",
          "to" => [recipient.ap_id],
          "cc" => []
        },
        local: false
      )

    conn =
      post(conn, "/api/v1/statuses", %{
        "status" => "Should fail",
        "in_reply_to_id" => Integer.to_string(dm.id)
      })

    assert response(conn, 422)
  end

  test "POST /api/v1/statuses supports visibility, spoiler_text, sensitive, and language",
       %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn =
      post(conn, "/api/v1/statuses", %{
        "status" => "Hello with options",
        "visibility" => "unlisted",
        "spoiler_text" => "cw",
        "sensitive" => "true",
        "language" => "en"
      })

    response = json_response(conn, 200)

    assert response["visibility"] == "unlisted"
    assert response["spoiler_text"] == "cw"
    assert response["sensitive"] == true
    assert response["language"] == "en"

    [object] = Objects.list_notes()
    assert object.data["summary"] == "cw"
    assert object.data["sensitive"] == true
    assert object.data["language"] == "en"
    assert object.data["to"] == [user.ap_id <> "/followers"]
    assert object.data["cc"] == ["https://www.w3.org/ns/activitystreams#Public"]
  end

  test "POST /api/v1/statuses rejects empty status", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn = post(conn, "/api/v1/statuses", %{"status" => "  "})
    assert response(conn, 422)
  end

  test "GET /api/v1/statuses/:id returns a status", %{conn: conn} do
    {:ok, _user} = Users.create_local_user("local")

    {:ok, _} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/1",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Hello show",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://example.com/users/alice/followers"]
        },
        local: false
      )

    [object] = Objects.list_notes()

    conn = get(conn, "/api/v1/statuses/#{object.id}")

    response = json_response(conn, 200)
    assert response["id"] == Integer.to_string(object.id)
    assert response["content"] == "<p>Hello show</p>"
  end

  test "GET /api/v1/statuses/:id does not expose direct statuses", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    {:ok, create} = Publish.post_note(user, "Secret DM", visibility: "direct")
    object = Objects.get_by_ap_id(create.object)

    conn = get(conn, "/api/v1/statuses/#{object.id}")
    assert response(conn, 404)
  end

  test "GET /api/v1/statuses/:id shows direct statuses to authorized recipients", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/dm-1",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Secret DM for local",
          "to" => [user.ap_id],
          "cc" => []
        },
        local: false
      )

    conn =
      conn
      |> put_req_header("authorization", "Bearer test-token")
      |> get("/api/v1/statuses/#{note.id}")

    response = json_response(conn, 200)
    assert response["id"] == Integer.to_string(note.id)
    assert response["content"] == "<p>Secret DM for local</p>"
    assert response["visibility"] == "direct"
  end

  test "POST /api/v1/statuses/:id/favourite creates a like", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, _} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/2",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Hello like",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://example.com/users/alice/followers"]
        },
        local: false
      )

    [object] = Objects.list_notes()

    conn = post(conn, "/api/v1/statuses/#{object.id}/favourite")
    response = json_response(conn, 200)
    assert response["account"]["username"] == "alice"

    assert Objects.get_by_type_actor_object("Like", user.ap_id, object.ap_id)
  end

  test "POST /api/v1/statuses/:id/favourite does not expose direct statuses to non-recipients", %{
    conn: conn
  } do
    {:ok, user} = Users.create_local_user("local")
    {:ok, recipient} = Users.create_local_user("bob")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/dm-favourite-1",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Secret DM for bob",
          "to" => [recipient.ap_id],
          "cc" => []
        },
        local: false
      )

    conn = post(conn, "/api/v1/statuses/#{note.id}/favourite")
    assert response(conn, 404)

    refute Objects.get_by_type_actor_object("Like", user.ap_id, note.ap_id)
  end

  test "POST /api/v1/statuses/:id/unfavourite creates an undo", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/3",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Hello unlike",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://example.com/users/alice/followers"]
        },
        local: false
      )

    like =
      %{
        "id" => "https://example.com/activities/like/1",
        "type" => "Like",
        "actor" => user.ap_id,
        "object" => note.ap_id
      }

    {:ok, like_object} = Pipeline.ingest(like, local: true)

    conn = post(conn, "/api/v1/statuses/#{note.id}/unfavourite")
    assert json_response(conn, 200)

    assert Objects.get_by_type_actor_object("Undo", user.ap_id, like_object.ap_id)
  end

  test "POST /api/v1/statuses/:id/bookmark creates a bookmark", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, _} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/bookmark-1",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Hello bookmark",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://example.com/users/alice/followers"]
        },
        local: false
      )

    [object] = Objects.list_notes()

    conn = post(conn, "/api/v1/statuses/#{object.id}/bookmark")
    response = json_response(conn, 200)

    assert response["id"] == Integer.to_string(object.id)
    assert response["bookmarked"] == true

    assert Relationships.get_by_type_actor_object("Bookmark", user.ap_id, object.ap_id)
  end

  test "POST /api/v1/statuses/:id/unbookmark removes a bookmark", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/bookmark-2",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Hello bookmark 2",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://example.com/users/alice/followers"]
        },
        local: false
      )

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Bookmark",
               actor: user.ap_id,
               object: note.ap_id
             })

    conn = post(conn, "/api/v1/statuses/#{note.id}/unbookmark")
    response = json_response(conn, 200)

    assert response["id"] == Integer.to_string(note.id)
    assert response["bookmarked"] == false

    refute Relationships.get_by_type_actor_object("Bookmark", user.ap_id, note.ap_id)
  end

  test "POST /api/v1/statuses/:id/reblog creates an announce", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/4",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Hello reblog",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://example.com/users/alice/followers"]
        },
        local: false
      )

    conn = post(conn, "/api/v1/statuses/#{note.id}/reblog")
    assert json_response(conn, 200)

    assert Objects.get_by_type_actor_object("Announce", user.ap_id, note.ap_id)
  end

  test "POST /api/v1/statuses/:id/reblog does not expose direct statuses to non-recipients", %{
    conn: conn
  } do
    {:ok, user} = Users.create_local_user("local")
    {:ok, recipient} = Users.create_local_user("bob")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/dm-reblog-1",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Secret DM for bob",
          "to" => [recipient.ap_id],
          "cc" => []
        },
        local: false
      )

    conn = post(conn, "/api/v1/statuses/#{note.id}/reblog")
    assert response(conn, 404)

    refute Objects.get_by_type_actor_object("Announce", user.ap_id, note.ap_id)
  end

  test "POST /api/v1/statuses/:id/reblog returns a reblog status", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/reblog-return",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Hello reblog",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://example.com/users/alice/followers"]
        },
        local: false
      )

    conn = post(conn, "/api/v1/statuses/#{note.id}/reblog")
    response = json_response(conn, 200)

    assert response["account"]["username"] == "local"
    assert response["content"] == ""

    assert is_map(response["reblog"])
    assert response["reblog"]["id"] == Integer.to_string(note.id)
    assert response["reblog"]["account"]["username"] == "alice"
    assert response["reblog"]["content"] == "<p>Hello reblog</p>"

    assert response["id"] != response["reblog"]["id"]
  end

  test "POST /api/v1/statuses/:id/unreblog creates an undo", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/5",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Hello unreblog",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://example.com/users/alice/followers"]
        },
        local: false
      )

    announce =
      %{
        "id" => "https://example.com/activities/announce/1",
        "type" => "Announce",
        "actor" => user.ap_id,
        "object" => note.ap_id
      }

    {:ok, announce_object} = Pipeline.ingest(announce, local: true)

    conn = post(conn, "/api/v1/statuses/#{note.id}/unreblog")
    assert json_response(conn, 200)

    assert Objects.get_by_type_actor_object("Undo", user.ap_id, announce_object.ap_id)
  end

  test "POST /api/v1/statuses/:id/favourite is idempotent", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, 2, fn _conn -> {:ok, user} end)

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/like-idempotent",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Hello like",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://example.com/users/alice/followers"]
        },
        local: false
      )

    conn = post(conn, "/api/v1/statuses/#{note.id}/favourite")
    assert json_response(conn, 200)

    conn = post(conn, "/api/v1/statuses/#{note.id}/favourite")
    assert json_response(conn, 200)

    assert Objects.count_by_type_object("Like", note.ap_id) == 1
  end

  test "POST /api/v1/statuses/:id/reblog is idempotent", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, 2, fn _conn -> {:ok, user} end)

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/reblog-idempotent",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Hello reblog",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://example.com/users/alice/followers"]
        },
        local: false
      )

    conn = post(conn, "/api/v1/statuses/#{note.id}/reblog")
    assert json_response(conn, 200)

    conn = post(conn, "/api/v1/statuses/#{note.id}/reblog")
    assert json_response(conn, 200)

    assert Objects.count_by_type_object("Announce", note.ap_id) == 1
  end

  test "POST /api/v1/statuses accepts media_ids and attaches media", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    ap_id = Endpoint.url() <> "/objects/" <> Ecto.UUID.generate()

    {:ok, media} =
      Objects.create_object(%{
        ap_id: ap_id,
        type: "Image",
        actor: user.ap_id,
        local: true,
        published: DateTime.utc_now(),
        data: %{
          "id" => ap_id,
          "type" => "Image",
          "mediaType" => "image/png",
          "url" => [
            %{
              "type" => "Link",
              "mediaType" => "image/png",
              "href" => Endpoint.url() <> "/uploads/media/#{user.id}/image.png"
            }
          ],
          "name" => ""
        }
      })

    conn =
      post(conn, "/api/v1/statuses", %{
        "status" => "Hello with media",
        "media_ids" => [Integer.to_string(media.id)]
      })

    response = json_response(conn, 200)

    assert response["content"] == "<p>Hello with media</p>"
    assert length(response["media_attachments"]) == 1

    attachment = Enum.at(response["media_attachments"], 0)
    assert attachment["id"] == Integer.to_string(media.id)
    assert attachment["type"] == "image"
    assert String.ends_with?(attachment["url"], "/uploads/media/#{user.id}/image.png")

    [note] = Objects.list_notes()
    assert is_list(note.data["attachment"])
    assert Enum.at(note.data["attachment"], 0)["type"] == "Image"
  end

  test "POST /api/v1/statuses allows media-only posts", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    ap_id = Endpoint.url() <> "/objects/" <> Ecto.UUID.generate()

    {:ok, media} =
      Objects.create_object(%{
        ap_id: ap_id,
        type: "Image",
        actor: user.ap_id,
        local: true,
        published: DateTime.utc_now(),
        data: %{
          "id" => ap_id,
          "type" => "Image",
          "mediaType" => "image/png",
          "url" => [
            %{
              "type" => "Link",
              "mediaType" => "image/png",
              "href" => Endpoint.url() <> "/uploads/media/#{user.id}/image.png"
            }
          ],
          "name" => ""
        }
      })

    conn =
      post(conn, "/api/v1/statuses", %{
        "status" => "  ",
        "media_ids" => [Integer.to_string(media.id)]
      })

    response = json_response(conn, 200)

    assert response["content"] == ""
    assert length(response["media_attachments"]) == 1
  end

  test "POST /api/v1/statuses rejects media_ids not owned by the user", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")
    {:ok, other} = Users.create_local_user("other")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    ap_id = Endpoint.url() <> "/objects/" <> Ecto.UUID.generate()

    {:ok, media} =
      Objects.create_object(%{
        ap_id: ap_id,
        type: "Image",
        actor: other.ap_id,
        local: true,
        published: DateTime.utc_now(),
        data: %{
          "id" => ap_id,
          "type" => "Image",
          "mediaType" => "image/png",
          "url" => [
            %{
              "type" => "Link",
              "mediaType" => "image/png",
              "href" => Endpoint.url() <> "/uploads/media/#{other.id}/image.png"
            }
          ],
          "name" => ""
        }
      })

    conn =
      post(conn, "/api/v1/statuses", %{
        "status" => "Hello with media",
        "media_ids" => [Integer.to_string(media.id)]
      })

    assert response(conn, 422)
  end

  test "POST /api/v1/statuses attaches uploaded media from /api/v1/media", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, 2, fn _conn -> {:ok, user} end)

    Egregoros.MediaStorage.Mock
    |> expect(:store_media, fn ^user, %Plug.Upload{filename: "image.png"} ->
      {:ok, "/uploads/media/#{user.id}/image.png"}
    end)

    upload =
      %Plug.Upload{
        path: tmp_upload_path(),
        filename: "image.png",
        content_type: "image/png"
      }

    conn = post(conn, "/api/v1/media", %{"file" => upload})
    media = json_response(conn, 200)

    conn =
      build_conn()
      |> post("/api/v1/statuses", %{
        "status" => "Hello with uploaded media",
        "media_ids" => [media["id"]]
      })

    response = json_response(conn, 200)

    assert response["content"] == "<p>Hello with uploaded media</p>"
    assert length(response["media_attachments"]) == 1
    assert Enum.at(response["media_attachments"], 0)["id"] == media["id"]
  end

  test "GET /api/v1/statuses/:id/context returns empty context", %{conn: conn} do
    {:ok, _user} = Users.create_local_user("local")

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/ctx-1",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Hello context",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://example.com/users/alice/followers"]
        },
        local: false
      )

    conn = get(conn, "/api/v1/statuses/#{note.id}/context")
    response = json_response(conn, 200)

    assert response["ancestors"] == []
    assert response["descendants"] == []
  end

  test "GET /api/v1/statuses/:id/context returns thread ancestors and descendants", %{conn: conn} do
    {:ok, _user} = Users.create_local_user("local")

    {:ok, root} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/root",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Root",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://example.com/users/alice/followers"]
        },
        local: false
      )

    {:ok, reply_1} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/reply-1",
          "type" => "Note",
          "actor" => "https://example.com/users/bob",
          "content" => "Reply 1",
          "inReplyTo" => root.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://example.com/users/bob/followers"]
        },
        local: false
      )

    {:ok, reply_2} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/reply-2",
          "type" => "Note",
          "actor" => "https://example.com/users/charlie",
          "content" => "Reply 2",
          "inReplyTo" => reply_1.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://example.com/users/charlie/followers"]
        },
        local: false
      )

    conn = get(conn, "/api/v1/statuses/#{reply_2.id}/context")
    response = json_response(conn, 200)

    assert Enum.map(response["ancestors"], & &1["content"]) == ["<p>Root</p>", "<p>Reply 1</p>"]
    assert response["descendants"] == []

    conn = get(conn, "/api/v1/statuses/#{root.id}/context")
    response = json_response(conn, 200)

    assert response["ancestors"] == []

    assert Enum.map(response["descendants"], & &1["content"]) == [
             "<p>Reply 1</p>",
             "<p>Reply 2</p>"
           ]
  end

  defp tmp_upload_path do
    path = Path.join(System.tmp_dir!(), "egregoros-test-upload-#{Ecto.UUID.generate()}")
    File.write!(path, <<0, 1, 2, 3>>)
    path
  end

  test "GET /api/v1/statuses/:id/favourited_by returns accounts who liked a status", %{conn: conn} do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    {:ok, create} = Publish.post_note(alice, "Hello")
    note = Objects.get_by_ap_id(create.object)

    {:ok, _like} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/activities/like/1",
          "type" => "Like",
          "actor" => bob.ap_id,
          "object" => note.ap_id
        },
        local: true
      )

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, alice} end)

    conn = get(conn, "/api/v1/statuses/#{note.id}/favourited_by")
    response = json_response(conn, 200)

    assert is_list(response)
    assert length(response) == 1
    assert Enum.at(response, 0)["username"] == "bob"
  end

  test "GET /api/v1/statuses/:id/favourited_by does not expose direct statuses to non-recipients",
       %{
         conn: conn
       } do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/dm-favourited-by-1",
          "type" => "Note",
          "actor" => "https://example.com/users/charlie",
          "content" => "Secret DM for bob",
          "to" => [bob.ap_id],
          "cc" => []
        },
        local: false
      )

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, alice} end)

    conn = get(conn, "/api/v1/statuses/#{note.id}/favourited_by")
    assert response(conn, 404)
  end

  test "GET /api/v1/statuses/:id/reblogged_by returns accounts who reblogged a status", %{
    conn: conn
  } do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    {:ok, create} = Publish.post_note(alice, "Hello")
    note = Objects.get_by_ap_id(create.object)

    {:ok, _announce} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/activities/announce/1",
          "type" => "Announce",
          "actor" => bob.ap_id,
          "object" => note.ap_id
        },
        local: true
      )

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, alice} end)

    conn = get(conn, "/api/v1/statuses/#{note.id}/reblogged_by")
    response = json_response(conn, 200)

    assert is_list(response)
    assert length(response) == 1
    assert Enum.at(response, 0)["username"] == "bob"
  end

  test "GET /api/v1/statuses/:id/reblogged_by does not expose direct statuses to non-recipients",
       %{
         conn: conn
       } do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/dm-reblogged-by-1",
          "type" => "Note",
          "actor" => "https://example.com/users/charlie",
          "content" => "Secret DM for bob",
          "to" => [bob.ap_id],
          "cc" => []
        },
        local: false
      )

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, alice} end)

    conn = get(conn, "/api/v1/statuses/#{note.id}/reblogged_by")
    assert response(conn, 404)
  end

  test "DELETE /api/v1/statuses/:id deletes a local status", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, create} = Publish.post_note(user, "Hello delete")
    note = Objects.get_by_ap_id(create.object)

    conn = delete(conn, "/api/v1/statuses/#{note.id}")
    response = json_response(conn, 200)

    assert response["id"] == Integer.to_string(note.id)
    assert Objects.get(note.id) == nil
  end

  test "missing status id returns 404 for write endpoints", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, 7, fn _conn -> {:ok, user} end)

    id = "999999"

    write_calls = [
      {:delete, "/api/v1/statuses/#{id}"},
      {:post, "/api/v1/statuses/#{id}/favourite"},
      {:post, "/api/v1/statuses/#{id}/unfavourite"},
      {:post, "/api/v1/statuses/#{id}/bookmark"},
      {:post, "/api/v1/statuses/#{id}/unbookmark"},
      {:post, "/api/v1/statuses/#{id}/reblog"},
      {:post, "/api/v1/statuses/#{id}/unreblog"}
    ]

    Enum.each(write_calls, fn
      {:delete, path} ->
        assert conn |> recycle() |> delete(path) |> response(404)

      {:post, path} ->
        assert conn |> recycle() |> post(path) |> response(404)
    end)
  end

  test "GET /api/v1/statuses/:id returns 404 for missing status", %{conn: conn} do
    conn = get(conn, "/api/v1/statuses/999999")
    assert response(conn, 404)
  end

  test "GET /api/v1/statuses/:id/context returns 404 for missing status", %{conn: conn} do
    conn = get(conn, "/api/v1/statuses/999999/context")
    assert response(conn, 404)
  end

  test "GET /api/v1/statuses/:id/context does not expose direct statuses to non-recipients", %{
    conn: conn
  } do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/dm-context-hidden-1",
          "type" => "Note",
          "actor" => "https://example.com/users/charlie",
          "content" => "Secret DM for bob",
          "to" => [bob.ap_id],
          "cc" => []
        },
        local: false
      )

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, alice} end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer test-token")
      |> get("/api/v1/statuses/#{note.id}/context")

    assert response(conn, 404)
  end

  test "oauth read status endpoints return 404 for missing status", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, 3, fn _conn -> {:ok, user} end)

    conn = conn |> recycle() |> get("/api/v1/statuses/999999/source")
    assert response(conn, 404)

    conn = conn |> recycle() |> get("/api/v1/statuses/999999/favourited_by")
    assert response(conn, 404)

    conn = conn |> recycle() |> get("/api/v1/statuses/999999/reblogged_by")
    assert response(conn, 404)
  end

  test "POST /api/v1/statuses ignores blank in_reply_to_id", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn =
      post(conn, "/api/v1/statuses", %{
        "status" => "Hello",
        "in_reply_to_id" => ""
      })

    response = json_response(conn, 200)
    assert response["content"] == "<p>Hello</p>"
    assert response["in_reply_to_id"] == nil
  end

  test "POST /api/v1/statuses rejects replies to missing statuses", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn =
      post(conn, "/api/v1/statuses", %{
        "status" => "Reply post",
        "in_reply_to_id" => "999999"
      })

    assert response(conn, 422)
  end

  test "POST /api/v1/statuses accepts integer in_reply_to_id when sent as JSON", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, parent} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/parent-int",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Parent post",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => []
        },
        local: false
      )

    body =
      Jason.encode!(%{
        "status" => "Reply post",
        "in_reply_to_id" => parent.id
      })

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> post("/api/v1/statuses", body)

    response = json_response(conn, 200)
    assert response["content"] == "<p>Reply post</p>"
    assert response["in_reply_to_id"] == Integer.to_string(parent.id)
  end

  test "POST /api/v1/statuses rejects unsupported in_reply_to_id types", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    body =
      Jason.encode!(%{
        "status" => "Reply post",
        "in_reply_to_id" => %{"oops" => "not a scalar id"}
      })

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> post("/api/v1/statuses", body)

    assert response(conn, 422)
  end

  test "PUT /api/v1/statuses/:id returns 404 for missing status", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    conn = put(conn, "/api/v1/statuses/999999", %{"status" => "Hello"})
    assert response(conn, 404)
  end

  test "PUT /api/v1/statuses/:id handles JSON boolean sensitive values", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, 3, fn _conn -> {:ok, user} end)

    {:ok, create} = Publish.post_note(user, "Original")
    note = Objects.get_by_ap_id(create.object)

    body = Jason.encode!(%{"status" => "Edited", "sensitive" => true})

    conn =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> put("/api/v1/statuses/#{note.id}", body)

    assert json_response(conn, 200)["sensitive"] == true

    body = Jason.encode!(%{"status" => "Edited again", "sensitive" => false})

    conn =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> put("/api/v1/statuses/#{note.id}", body)

    assert json_response(conn, 200)["sensitive"] == false

    conn =
      put(conn |> recycle(), "/api/v1/statuses/#{note.id}", %{
        "status" => "Edited 3",
        "sensitive" => "false"
      })

    assert json_response(conn, 200)["sensitive"] == false
  end

  test "bookmark/unbookmark/unfavourite/unreblog do not expose direct statuses to non-recipients",
       %{
         conn: conn
       } do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/dm-hidden-actions-1",
          "type" => "Note",
          "actor" => "https://example.com/users/charlie",
          "content" => "Secret DM for bob",
          "to" => [bob.ap_id],
          "cc" => []
        },
        local: false
      )

    Egregoros.Auth.Mock
    |> expect(:current_user, 4, fn _conn -> {:ok, alice} end)

    conn = post(conn, "/api/v1/statuses/#{note.id}/unfavourite")
    assert response(conn, 404)

    conn = post(conn |> recycle(), "/api/v1/statuses/#{note.id}/bookmark")
    assert response(conn, 404)

    conn = post(conn |> recycle(), "/api/v1/statuses/#{note.id}/unbookmark")
    assert response(conn, 404)

    conn = post(conn |> recycle(), "/api/v1/statuses/#{note.id}/unreblog")
    assert response(conn, 404)
  end
end
