defmodule EgregorosWeb.MastodonAPI.NotificationRendererTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Object
  alias Egregoros.Users
  alias EgregorosWeb.MastodonAPI.NotificationRenderer

  test "render_notifications/2 returns [] for non-list input" do
    {:ok, alice} = Users.create_local_user("alice")
    assert NotificationRenderer.render_notifications(nil, alice) == []
  end

  test "renders follow notifications without a status" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    {:ok, follow} =
      Objects.create_object(%{
        ap_id: "https://remote.example/activities/follow/1",
        type: "Follow",
        actor: bob.ap_id,
        object: alice.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/activities/follow/1",
          "type" => "Follow",
          "actor" => bob.ap_id,
          "object" => alice.ap_id
        }
      })

    rendered = NotificationRenderer.render_notification(follow, alice)

    assert rendered["type"] == "follow"
    assert rendered["status"] == nil
    assert rendered["account"]["username"] == "bob"
  end

  test "renders favourite notifications with a rendered status" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    {:ok, note} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/1",
        type: "Note",
        actor: alice.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/objects/1",
          "type" => "Note",
          "actor" => alice.ap_id,
          "content" => "<p>hello</p>"
        }
      })

    {:ok, like} =
      Objects.create_object(%{
        ap_id: "https://remote.example/activities/like/1",
        type: "Like",
        actor: bob.ap_id,
        object: note.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/activities/like/1",
          "type" => "Like",
          "actor" => bob.ap_id,
          "object" => note.ap_id
        }
      })

    rendered = NotificationRenderer.render_notification(like, alice)

    assert rendered["type"] == "favourite"
    assert %{"id" => note_id} = rendered["status"]
    assert note_id == note.id
  end

  test "renders reblog notifications with a rendered status" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    {:ok, note} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/1",
        type: "Note",
        actor: alice.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/objects/1",
          "type" => "Note",
          "actor" => alice.ap_id,
          "content" => "<p>hello</p>"
        }
      })

    {:ok, announce} =
      Objects.create_object(%{
        ap_id: "https://remote.example/activities/announce/1",
        type: "Announce",
        actor: bob.ap_id,
        object: note.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/activities/announce/1",
          "type" => "Announce",
          "actor" => bob.ap_id,
          "object" => note.ap_id
        }
      })

    rendered = NotificationRenderer.render_notification(announce, alice)

    assert rendered["type"] == "reblog"
    assert %{"id" => note_id} = rendered["status"]
    assert note_id == note.id
  end

  test "renders unknown actors with a fallback acct" do
    {:ok, alice} = Users.create_local_user("alice")

    {:ok, follow} =
      Objects.create_object(%{
        ap_id: "https://remote.example/activities/follow/1",
        type: "Follow",
        actor: "https://remote.example/users/mallory",
        object: alice.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/activities/follow/1",
          "type" => "Follow",
          "actor" => "https://remote.example/users/mallory",
          "object" => alice.ap_id
        }
      })

    rendered = NotificationRenderer.render_notification(follow, alice)

    assert rendered["account"]["id"] == "https://remote.example/users/mallory"
    assert rendered["account"]["acct"] == "mallory"
  end

  test "renders Note notifications as mention and marks them seen" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    {:ok, note} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/1",
        type: "Note",
        actor: bob.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/objects/1",
          "type" => "Note",
          "actor" => bob.ap_id,
          "content" => "<p>hello</p>"
        }
      })

    alice = %{alice | notifications_last_seen_id: note.id}

    rendered = NotificationRenderer.render_notification(note, alice)

    assert rendered["type"] == "mention"
    assert %{"id" => note_id} = rendered["status"]
    assert note_id == note.id
    assert rendered["pleroma"]["is_seen"]
  end

  test "render_notification/2 falls back to list rendering for non-user callers" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    {:ok, follow} =
      Objects.create_object(%{
        ap_id: "https://remote.example/activities/follow/1",
        type: "Follow",
        actor: bob.ap_id,
        object: alice.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/activities/follow/1",
          "type" => "Follow",
          "actor" => bob.ap_id,
          "object" => alice.ap_id
        }
      })

    rendered = NotificationRenderer.render_notification(follow, nil)

    assert rendered["type"] == "follow"
    assert rendered["account"]["username"] == "bob"
  end

  test "render_notification/2 returns an unknown payload for invalid activities" do
    {:ok, alice} = Users.create_local_user("alice")

    rendered = NotificationRenderer.render_notification(:not_an_object, alice)

    assert rendered["id"] == "unknown"
    assert rendered["type"] == "unknown"
    assert rendered["status"] == nil
  end

  test "downcases unknown types and handles unknown actors" do
    {:ok, alice} = Users.create_local_user("alice")

    activity = %Object{
      id: 123,
      type: "EmojiReact",
      actor: nil,
      inserted_at: NaiveDateTime.utc_now()
    }

    rendered = NotificationRenderer.render_notification(activity, alice)

    assert rendered["type"] == "emojireact"
    assert rendered["account"]["id"] == "unknown"
    assert is_binary(rendered["created_at"])
  end

  test "falls back to current timestamp for unknown datetime and type" do
    {:ok, alice} = Users.create_local_user("alice")

    activity = %Object{id: 123, type: nil, actor: nil}

    rendered = NotificationRenderer.render_notification(activity, alice)

    assert rendered["type"] == "unknown"
    assert is_binary(rendered["created_at"])
  end

  test "render_notifications/2 returns an unknown notification for unknown activity shapes" do
    {:ok, alice} = Users.create_local_user("alice")

    [rendered] = NotificationRenderer.render_notifications([%{}], alice)

    assert rendered["id"] == "unknown"
    assert rendered["type"] == "unknown"
    assert rendered["status"] == nil
    assert rendered["pleroma"]["is_seen"] == false
  end

  test "render_notifications/2 treats blank actor ids as unknown" do
    {:ok, alice} = Users.create_local_user("alice")

    activity = %Object{id: 123, type: "Follow", actor: " ", inserted_at: DateTime.utc_now()}

    [rendered] = NotificationRenderer.render_notifications([activity], alice)

    assert rendered["type"] == "follow"
    assert rendered["account"]["id"] == "unknown"
  end
end
