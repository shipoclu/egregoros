defmodule PleromaReduxWeb.MastodonAPI.StreamingSocketTest do
  use PleromaRedux.DataCase, async: true

  alias PleromaRedux.Activities.Note
  alias PleromaRedux.Objects
  alias PleromaRedux.Pipeline
  alias PleromaRedux.Relationships
  alias PleromaRedux.Users
  alias PleromaReduxWeb.MastodonAPI.StreamingSocket

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

    assert {:push, {:text, payload}, ^state} =
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

    assert {:ok, ^state} = StreamingSocket.handle_info({:post_created, note}, state)
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

    assert {:push, {:text, payload}, ^state} =
             StreamingSocket.handle_info({:post_created, note}, state)

    assert %{"event" => "update", "payload" => status_payload, "stream" => ["public"]} =
             Jason.decode!(payload)

    assert is_binary(status_payload)
    assert %{"id" => _id} = Jason.decode!(status_payload)
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

    assert {:ok, ^state} = StreamingSocket.handle_info({:post_created, note}, state)
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

    assert {:ok, ^state} = StreamingSocket.handle_info({:post_created, note}, state)
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

    assert {:push, {:text, payload}, ^state} =
             StreamingSocket.handle_info({:notification_created, like}, state)

    assert %{"event" => "notification", "payload" => notification_payload, "stream" => ["user"]} =
             Jason.decode!(payload)

    assert is_binary(notification_payload)
    assert %{"id" => _id, "type" => _type} = Jason.decode!(notification_payload)
  end

  test "handle_in returns an error when subscribing to user streams without a current user" do
    {:ok, state} = StreamingSocket.init(%{streams: [], current_user: nil})

    assert {:push, {:text, reply}, ^state} =
             StreamingSocket.handle_in(
               {Jason.encode!(%{"type" => "subscribe", "stream" => "user"}), opcode: :text},
               state
             )

    assert %{"error" => "Missing access token", "status" => 401} = Jason.decode!(reply)
  end

  test "handle_in ignores unknown messages" do
    {:ok, state} = StreamingSocket.init(%{streams: [], current_user: nil})
    assert {:ok, ^state} = StreamingSocket.handle_in({"ping", opcode: :text}, state)
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
