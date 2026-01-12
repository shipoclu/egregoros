defmodule Egregoros.TimelineFunctionsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Timeline
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  test "topic helpers handle non-binary ap_ids" do
    assert Timeline.public_topic() == "timeline:public"
    assert Timeline.user_topic(nil) == "timeline:user:unknown"
  end

  test "broadcast helpers are no-ops for non-object terms" do
    assert :ok = Timeline.broadcast_post(:not_an_object)
    assert :ok = Timeline.broadcast_post_updated(:not_an_object)
    assert :ok = Timeline.broadcast_post_deleted(:not_an_object)
  end

  test "broadcast_post/1, broadcast_post_updated/1 and broadcast_post_deleted/1 publish to public and user topics" do
    {:ok, alice} = Users.create_local_user("alice")

    Timeline.subscribe_public()
    Timeline.subscribe_user(alice)

    object = %Egregoros.Object{
      ap_id: Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
      type: "Note",
      actor: alice.ap_id,
      local: true,
      data: %{
        "id" => "https://egregoros.example/objects/1",
        "type" => "Note",
        "attributedTo" => alice.ap_id,
        "to" => [@as_public],
        "cc" => [alice.ap_id <> "/followers"],
        "content" => "hello"
      }
    }

    assert :ok = Timeline.broadcast_post(object)
    assert_receive {:post_created, ^object}
    assert_receive {:post_created, ^object}

    assert :ok = Timeline.broadcast_post_updated(object)
    assert_receive {:post_updated, ^object}
    assert_receive {:post_updated, ^object}

    assert :ok = Timeline.broadcast_post_deleted(object)
    assert_receive {:post_deleted, ^object}
    assert_receive {:post_deleted, ^object}
  end

  test "reset/0 clears note objects" do
    {:ok, alice} = Users.create_local_user("alice")
    ap_id = Endpoint.url() <> "/objects/" <> Ecto.UUID.generate()

    {:ok, _note} =
      Objects.create_object(%{
        ap_id: ap_id,
        type: "Note",
        actor: alice.ap_id,
        data: %{
          "id" => ap_id,
          "type" => "Note",
          "attributedTo" => alice.ap_id,
          "to" => [@as_public],
          "content" => "hello"
        },
        local: true
      })

    assert Enum.any?(Timeline.list_posts(), &(&1.ap_id == ap_id))

    assert {count, nil} = Timeline.reset()
    assert is_integer(count)

    refute Enum.any?(Timeline.list_posts(), &(&1.ap_id == ap_id))
  end
end
