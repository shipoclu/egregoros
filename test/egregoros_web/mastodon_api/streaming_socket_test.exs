defmodule EgregorosWeb.MastodonAPI.StreamingSocketTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Activities.Note
  alias Egregoros.OAuth
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users
  alias EgregorosWeb.MastodonAPI.StreamingSocket

  defp create_access_token!(user) do
    {:ok, app} =
      OAuth.create_application(%{
        "client_name" => "Pleroma FE",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read write follow"
      })

    {:ok, auth_code} =
      OAuth.create_authorization_code(app, user, "urn:ietf:wg:oauth:2.0:oob", "read")

    {:ok, token} =
      OAuth.exchange_code_for_token(%{
        "grant_type" => "authorization_code",
        "code" => auth_code.code,
        "client_id" => app.client_id,
        "client_secret" => app.client_secret,
        "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
      })

    token.token
  end

  test "subscribing to the user stream computes home_actor_ids" do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, followed} = Users.create_user(remote_user_attrs("bob@example.com"))

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: user.ap_id,
               object: followed.ap_id,
               activity_ap_id: "https://example.com/activities/follow/1"
             })

    assert {:ok, state} = StreamingSocket.init(%{streams: [], current_user: user})

    assert {:ok, state} =
             StreamingSocket.handle_in(
               {Jason.encode!(%{"type" => "subscribe", "stream" => "user"}), opcode: :text},
               state
             )

    assert MapSet.member?(state.home_actor_ids, user.ap_id)
    assert MapSet.member?(state.home_actor_ids, followed.ap_id)
  end

  test "heartbeat pushes a websocket ping frame" do
    {:ok, state} = StreamingSocket.init(%{streams: [], current_user: nil})

    assert {:push, {:ping, ""}, _state} = StreamingSocket.handle_info(:heartbeat, state)
  end

  test "handle_in ignores non-text websocket frames" do
    {:ok, state} = StreamingSocket.init(%{streams: [], current_user: nil})
    assert {:ok, ^state} = StreamingSocket.handle_in({"ping", opcode: :binary}, state)
  end

  test "delivers user timeline updates for followed actors" do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, followed} = Users.create_user(remote_user_attrs("bob@example.com"))
    public = "https://www.w3.org/ns/activitystreams#Public"

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: user.ap_id,
               object: followed.ap_id,
               activity_ap_id: "https://example.com/activities/follow/1"
             })

    {:ok, state} = StreamingSocket.init(%{streams: ["user"], current_user: user})

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/1",
               type: "Note",
               actor: followed.ap_id,
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/1",
                 "type" => "Note",
                 "attributedTo" => followed.ap_id,
                 "to" => [public],
                 "cc" => [followed.ap_id <> "/followers"],
                 "content" => "<p>Hello</p>"
               }
             })

    assert {:push, {:text, payload}, _state} =
             StreamingSocket.handle_info({:post_created, note}, state)

    assert %{"event" => "update", "payload" => status_payload, "stream" => ["user"]} =
             Jason.decode!(payload)

    assert is_binary(status_payload)
    assert %{"id" => _id} = Jason.decode!(status_payload)
  end

  test "filters user streams when the actor is not in the home timeline set" do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, state} = StreamingSocket.init(%{streams: ["user"], current_user: user})

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/2",
               type: "Note",
               actor: "https://remote.example/users/stranger",
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/2",
                 "type" => "Note",
                 "attributedTo" => "https://remote.example/users/stranger",
                 "content" => "<p>Hello</p>"
               }
             })

    assert {:ok, _state} = StreamingSocket.handle_info({:post_created, note}, state)
  end

  test "delivers direct messages to the user stream even when the actor is not followed" do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, state} = StreamingSocket.init(%{streams: ["user"], current_user: user})

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/direct-mention",
               type: "Note",
               actor: "https://remote.example/users/stranger",
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/direct-mention",
                 "type" => "Note",
                 "attributedTo" => "https://remote.example/users/stranger",
                 "to" => [user.ap_id],
                 "cc" => [],
                 "content" => "<p>Secret</p>"
               }
             })

    assert {:push, {:text, payload}, _state} =
             StreamingSocket.handle_info({:post_created, note}, state)

    assert %{"event" => "update", "payload" => status_payload, "stream" => ["user"]} =
             Jason.decode!(payload)

    assert is_binary(status_payload)
    assert %{"id" => _id} = Jason.decode!(status_payload)
  end

  test "delivers direct messages addressed via bto/bcc/audience to the user stream" do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, state} = StreamingSocket.init(%{streams: ["user"], current_user: user})

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/direct-bcc",
               type: "Note",
               actor: "https://remote.example/users/stranger",
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/direct-bcc",
                 "type" => "Note",
                 "attributedTo" => "https://remote.example/users/stranger",
                 "to" => [],
                 "cc" => [],
                 "bcc" => [user.ap_id],
                 "content" => "<p>Secret</p>"
               }
             })

    assert {:push, {:text, payload}, _state} =
             StreamingSocket.handle_info({:post_created, note}, state)

    assert %{"event" => "update", "payload" => status_payload, "stream" => ["user"]} =
             Jason.decode!(payload)

    assert is_binary(status_payload)
    assert %{"id" => _id} = Jason.decode!(status_payload)
  end

  test "delivers public timeline updates without a current user" do
    {:ok, state} = StreamingSocket.init(%{streams: ["public"], current_user: nil})
    public = "https://www.w3.org/ns/activitystreams#Public"

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/3",
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/3",
                 "type" => "Note",
                 "attributedTo" => "https://remote.example/users/alice",
                 "to" => [public],
                 "cc" => ["https://remote.example/users/alice/followers"],
                 "content" => "<p>Hello</p>"
               }
             })

    assert {:push, {:text, payload}, _state} =
             StreamingSocket.handle_info({:post_created, note}, state)

    assert %{"event" => "update", "payload" => status_payload, "stream" => ["public"]} =
             Jason.decode!(payload)

    assert is_binary(status_payload)
    assert %{"id" => _id} = Jason.decode!(status_payload)
  end

  test "does not deliver announce updates when the reblogged object is missing" do
    {:ok, state} = StreamingSocket.init(%{streams: ["public"], current_user: nil})
    public = "https://www.w3.org/ns/activitystreams#Public"

    assert {:ok, announce} =
             Objects.create_object(%{
               ap_id: "https://remote.example/activities/announce/missing",
               type: "Announce",
               actor: "https://remote.example/users/alice",
               object: "https://remote.example/objects/missing",
               local: false,
               data: %{
                 "id" => "https://remote.example/activities/announce/missing",
                 "type" => "Announce",
                 "actor" => "https://remote.example/users/alice",
                 "object" => "https://remote.example/objects/missing",
                 "to" => [public],
                 "cc" => []
               }
             })

    assert {:ok, _state} = StreamingSocket.handle_info({:post_created, announce}, state)
  end

  test "delivers announce updates when the reblogged object exists" do
    {:ok, state} = StreamingSocket.init(%{streams: ["public"], current_user: nil})
    public = "https://www.w3.org/ns/activitystreams#Public"
    announced_id = "https://remote.example/objects/announced"

    assert {:ok, _note} =
             Objects.create_object(%{
               ap_id: announced_id,
               type: "Note",
               actor: "https://remote.example/users/bob",
               local: false,
               data: %{
                 "id" => announced_id,
                 "type" => "Note",
                 "attributedTo" => "https://remote.example/users/bob",
                 "to" => [public],
                 "cc" => ["https://remote.example/users/bob/followers"],
                 "content" => "<p>Hello</p>"
               }
             })

    assert {:ok, announce} =
             Objects.create_object(%{
               ap_id: "https://remote.example/activities/announce/ready",
               type: "Announce",
               actor: "https://remote.example/users/alice",
               object: announced_id,
               local: false,
               data: %{
                 "id" => "https://remote.example/activities/announce/ready",
                 "type" => "Announce",
                 "actor" => "https://remote.example/users/alice",
                 "object" => announced_id,
                 "to" => [public],
                 "cc" => []
               }
             })

    assert {:push, {:text, payload}, _state} =
             StreamingSocket.handle_info({:post_created, announce}, state)

    assert %{"event" => "update", "payload" => status_payload, "stream" => ["public"]} =
             Jason.decode!(payload)

    assert %{"reblog" => %{"id" => _id}} = Jason.decode!(status_payload)
  end

  test "does not deliver direct messages to the public stream" do
    {:ok, state} = StreamingSocket.init(%{streams: ["public"], current_user: nil})

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/direct-public",
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/direct-public",
                 "type" => "Note",
                 "attributedTo" => "https://remote.example/users/alice",
                 "to" => [],
                 "cc" => [],
                 "content" => "<p>Secret</p>"
               }
             })

    assert {:ok, _state} = StreamingSocket.handle_info({:post_created, note}, state)
  end

  test "does not deliver unlisted statuses to the public stream" do
    {:ok, state} = StreamingSocket.init(%{streams: ["public"], current_user: nil})
    public = "https://www.w3.org/ns/activitystreams#Public"

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/unlisted-public-stream",
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/unlisted-public-stream",
                 "type" => "Note",
                 "attributedTo" => "https://remote.example/users/alice",
                 "to" => ["https://remote.example/users/alice/followers"],
                 "cc" => [public],
                 "content" => "<p>Unlisted</p>"
               }
             })

    assert {:ok, _state} = StreamingSocket.handle_info({:post_created, note}, state)
  end

  test "does not deliver non-visible messages to the user stream" do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, followed} = Users.create_user(remote_user_attrs("bob@example.com"))

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Follow",
               actor: user.ap_id,
               object: followed.ap_id,
               activity_ap_id: "https://example.com/activities/follow/1"
             })

    {:ok, state} = StreamingSocket.init(%{streams: ["user"], current_user: user})

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/direct-user",
               type: "Note",
               actor: followed.ap_id,
               local: false,
               data: %{
                 "id" => "https://remote.example/objects/direct-user",
                 "type" => "Note",
                 "attributedTo" => followed.ap_id,
                 "to" => [],
                 "cc" => [],
                 "content" => "<p>Secret</p>"
               }
             })

    assert {:ok, _state} = StreamingSocket.handle_info({:post_created, note}, state)
  end

  test "delivers notifications for signed-in user streams" do
    {:ok, user} = Users.create_local_user("alice")

    assert {:ok, note} = Pipeline.ingest(Note.build(user, "Hello"), local: true)

    {:ok, like_actor} = Users.create_user(remote_user_attrs("bob@example.com"))

    activity = %{
      "id" => "https://remote.example/activities/like/1",
      "type" => "Like",
      "actor" => like_actor.ap_id,
      "object" => note.ap_id
    }

    assert {:ok, like} = Pipeline.ingest(activity, local: false)

    {:ok, state} = StreamingSocket.init(%{streams: ["user"], current_user: user})

    assert {:push, {:text, payload}, _state} =
             StreamingSocket.handle_info({:notification_created, like}, state)

    assert %{"event" => "notification", "payload" => notification_payload, "stream" => ["user"]} =
             Jason.decode!(payload)

    assert is_binary(notification_payload)
    assert %{"id" => _id, "type" => _type} = Jason.decode!(notification_payload)
  end

  test "does not deliver notification updates when no notification streams are subscribed" do
    {:ok, user} = Users.create_local_user("alice")
    assert {:ok, note} = Pipeline.ingest(Note.build(user, "Hello"), local: true)

    {:ok, like_actor} = Users.create_user(remote_user_attrs("bob@example.com"))

    activity = %{
      "id" => "https://remote.example/activities/like/2",
      "type" => "Like",
      "actor" => like_actor.ap_id,
      "object" => note.ap_id
    }

    assert {:ok, like} = Pipeline.ingest(activity, local: false)

    {:ok, state} = StreamingSocket.init(%{streams: ["public"], current_user: user})

    assert {:ok, _state} = StreamingSocket.handle_info({:notification_created, like}, state)
  end

  test "handle_in returns an error when subscribing to user streams without a current user" do
    {:ok, state} = StreamingSocket.init(%{streams: [], current_user: nil})

    assert {:push, {:text, reply}, _state} =
             StreamingSocket.handle_in(
               {Jason.encode!(%{"type" => "subscribe", "stream" => "user"}), opcode: :text},
               state
             )

    assert %{"error" => "Missing access token", "status" => 401} = Jason.decode!(reply)
  end

  test "handle_in supports pleroma:authenticate for streaming clients" do
    {:ok, user} = Users.create_local_user("alice")
    token = create_access_token!(user)

    {:ok, state} = StreamingSocket.init(%{streams: [], current_user: nil, oauth_token: nil})

    assert {:push, {:text, reply}, state} =
             StreamingSocket.handle_in(
               {Jason.encode!(%{"type" => "pleroma:authenticate", "token" => token}),
                opcode: :text},
               state
             )

    assert state.current_user.id == user.id

    decoded = Jason.decode!(reply)
    assert decoded["event"] == "pleroma:respond"

    payload = Jason.decode!(decoded["payload"])
    assert payload["type"] == "pleroma:authenticate"
    assert payload["result"] == "success"
  end

  test "handle_in returns an error for invalid pleroma:authenticate tokens" do
    {:ok, state} = StreamingSocket.init(%{streams: [], current_user: nil, oauth_token: nil})

    assert {:push, {:text, reply}, state} =
             StreamingSocket.handle_in(
               {Jason.encode!(%{"type" => "pleroma:authenticate", "token" => "nope"}),
                opcode: :text},
               state
             )

    assert state.current_user == nil

    decoded = Jason.decode!(reply)
    assert decoded["event"] == "pleroma:respond"

    payload = Jason.decode!(decoded["payload"])
    assert payload["type"] == "pleroma:authenticate"
    refute payload["result"] == "success"
    assert is_binary(payload["error"])
  end

  test "handle_in returns an error when subscribing to unknown streams" do
    {:ok, state} = StreamingSocket.init(%{streams: [], current_user: nil})

    assert {:push, {:text, reply}, _state} =
             StreamingSocket.handle_in(
               {Jason.encode!(%{"type" => "subscribe", "stream" => "nope"}), opcode: :text},
               state
             )

    assert %{"error" => "Unknown stream type", "status" => 400} = Jason.decode!(reply)
  end

  test "handle_in ignores unsubscribe events for unknown or non-subscribed streams" do
    {:ok, state} = StreamingSocket.init(%{streams: [], current_user: nil})

    assert {:ok, ^state} =
             StreamingSocket.handle_in(
               {Jason.encode!(%{"type" => "unsubscribe", "stream" => "nope"}), opcode: :text},
               state
             )

    assert {:ok, ^state} =
             StreamingSocket.handle_in(
               {Jason.encode!(%{"type" => "unsubscribe", "stream" => "public"}), opcode: :text},
               state
             )
  end

  test "handle_in removes streams on unsubscribe and updates subscription flags" do
    {:ok, state} = StreamingSocket.init(%{streams: ["public"], current_user: nil})
    assert MapSet.member?(state.streams, "public")
    assert state.timeline_public_subscribed == true

    assert {:ok, state} =
             StreamingSocket.handle_in(
               {Jason.encode!(%{"type" => "unsubscribe", "stream" => "public"}), opcode: :text},
               state
             )

    refute MapSet.member?(state.streams, "public")
    assert state.timeline_public_subscribed == false
  end

  test "handle_in ignores unknown messages" do
    {:ok, state} = StreamingSocket.init(%{streams: [], current_user: nil})
    assert {:ok, ^state} = StreamingSocket.handle_in({"ping", opcode: :text}, state)
  end

  test "handle_in ignores invalid json messages" do
    {:ok, state} = StreamingSocket.init(%{streams: [], current_user: nil})
    assert {:ok, ^state} = StreamingSocket.handle_in({"{", opcode: :text}, state)
  end

  test "pushes updates to both public streams when both are subscribed" do
    {:ok, state} = StreamingSocket.init(%{streams: ["public", "public:local"], current_user: nil})

    public = "https://www.w3.org/ns/activitystreams#Public"
    uuid = Ecto.UUID.generate()
    ap_id = "https://remote.example/objects/#{uuid}"

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: ap_id,
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: true,
               data: %{
                 "id" => ap_id,
                 "type" => "Note",
                 "attributedTo" => "https://remote.example/users/alice",
                 "to" => [public],
                 "cc" => [],
                 "content" => "<p>Hello</p>"
               }
             })

    assert {:push, messages, _state} = StreamingSocket.handle_info({:post_created, note}, state)
    assert is_list(messages)
    assert length(messages) == 2

    streams =
      Enum.map(messages, fn {:text, payload} ->
        %{"stream" => [stream]} = Jason.decode!(payload)
        stream
      end)

    assert Enum.sort(streams) == ["public", "public:local"]
  end

  test "skips pushing updates for objects with an ap_id that has already been seen" do
    {:ok, state} = StreamingSocket.init(%{streams: ["public"], current_user: nil})
    public = "https://www.w3.org/ns/activitystreams#Public"
    uuid = Ecto.UUID.generate()
    ap_id = "https://remote.example/objects/#{uuid}"

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: ap_id,
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => ap_id,
                 "type" => "Note",
                 "attributedTo" => "https://remote.example/users/alice",
                 "to" => [public],
                 "cc" => [],
                 "content" => "<p>Hello</p>"
               }
             })

    assert {:push, {:text, _payload}, state} =
             StreamingSocket.handle_info({:post_created, note}, state)

    assert {:ok, _state} = StreamingSocket.handle_info({:post_created, note}, state)
  end

  test "delivers user stream updates for recipient fields expressed as maps" do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, state} = StreamingSocket.init(%{streams: ["user"], current_user: user})

    uuid = Ecto.UUID.generate()
    ap_id = "https://remote.example/objects/dm/#{uuid}"

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: ap_id,
               type: "Note",
               actor: "https://remote.example/users/stranger",
               local: false,
               data: %{
                 "id" => ap_id,
                 "type" => "Note",
                 "attributedTo" => "https://remote.example/users/stranger",
                 "to" => [%{"id" => user.ap_id}],
                 "cc" => [],
                 "content" => "<p>Secret</p>"
               }
             })

    note = %{note | data: Map.put(note.data, "bcc", [%{id: user.ap_id}])}

    assert {:push, {:text, payload}, _state} =
             StreamingSocket.handle_info({:post_created, note}, state)

    assert %{"event" => "update", "stream" => ["user"]} = Jason.decode!(payload)
  end

  test "unsubscribing from the user stream clears home timeline and notifications subscriptions" do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, state} = StreamingSocket.init(%{streams: ["user"], current_user: user})

    assert MapSet.member?(state.streams, "user")
    assert state.timeline_user_subscribed == true
    assert state.notifications_subscribed == true
    assert MapSet.member?(state.home_actor_ids, user.ap_id)

    assert {:ok, state} =
             StreamingSocket.handle_in(
               {Jason.encode!(%{"type" => "unsubscribe", "stream" => "user"}), opcode: :text},
               state
             )

    refute MapSet.member?(state.streams, "user")
    assert state.timeline_user_subscribed == false
    assert state.notifications_subscribed == false
    assert state.home_actor_ids == MapSet.new()
  end

  test "does not push updates for unknown streams" do
    {:ok, state} = StreamingSocket.init(%{streams: ["nope"], current_user: nil})
    public = "https://www.w3.org/ns/activitystreams#Public"
    uuid = Ecto.UUID.generate()
    ap_id = "https://remote.example/objects/#{uuid}"

    assert {:ok, note} =
             Objects.create_object(%{
               ap_id: ap_id,
               type: "Note",
               actor: "https://remote.example/users/alice",
               local: false,
               data: %{
                 "id" => ap_id,
                 "type" => "Note",
                 "attributedTo" => "https://remote.example/users/alice",
                 "to" => [public],
                 "cc" => [],
                 "content" => "<p>Hello</p>"
               }
             })

    assert {:ok, _state} = StreamingSocket.handle_info({:post_created, note}, state)
  end

  test "handle_info ignores unknown messages" do
    {:ok, state} = StreamingSocket.init(%{streams: [], current_user: nil})
    assert {:ok, ^state} = StreamingSocket.handle_info(:nope, state)
  end

  test "handles announce updates where the announced ap_id cannot be derived" do
    {:ok, state} = StreamingSocket.init(%{streams: ["public"], current_user: nil})
    public = "https://www.w3.org/ns/activitystreams#Public"
    uuid = Ecto.UUID.generate()

    assert {:ok, announce} =
             Objects.create_object(%{
               ap_id: "https://remote.example/activities/announce/no-object/#{uuid}",
               type: "Announce",
               actor: "https://remote.example/users/alice",
               object: nil,
               local: false,
               data: %{
                 "id" => "https://remote.example/activities/announce/no-object/#{uuid}",
                 "type" => "Announce",
                 "actor" => "https://remote.example/users/alice",
                 "object" => nil,
                 "to" => [public],
                 "cc" => []
               }
             })

    assert {:push, {:text, payload}, _state} =
             StreamingSocket.handle_info({:post_created, announce}, state)

    assert %{"event" => "update", "stream" => ["public"]} =
             Jason.decode!(payload)
  end

  defp remote_user_attrs(handle) do
    [nickname, domain] = String.split(handle, "@", parts: 2)

    %{
      nickname: nickname,
      domain: domain,
      ap_id: "https://#{domain}/users/#{nickname}",
      inbox: "https://#{domain}/users/#{nickname}/inbox",
      outbox: "https://#{domain}/users/#{nickname}/outbox",
      public_key: "remote-key",
      private_key: nil,
      local: false
    }
  end
end
