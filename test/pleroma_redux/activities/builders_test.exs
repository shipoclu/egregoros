defmodule PleromaRedux.Activities.BuildersTest do
  use PleromaRedux.DataCase, async: true

  alias PleromaRedux.Activities.Announce
  alias PleromaRedux.Activities.EmojiReact
  alias PleromaRedux.Activities.Like
  alias PleromaRedux.Activities.Undo
  alias PleromaRedux.Objects
  alias PleromaRedux.Users

  @public "https://www.w3.org/ns/activitystreams#Public"

  test "Like.build/2 addresses public objects to followers + object actor" do
    {:ok, actor} = Users.create_local_user("alice")

    {:ok, note_object} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/1",
        type: "Note",
        actor: "https://remote.example/users/bob",
        object: nil,
        data: %{
          "id" => "https://remote.example/objects/1",
          "type" => "Note",
          "actor" => "https://remote.example/users/bob",
          "to" => [@public],
          "content" => "hello"
        },
        local: false
      })

    like = Like.build(actor, note_object)
    assert like["type"] == "Like"
    assert like["actor"] == actor.ap_id
    assert like["object"] == note_object.ap_id
    assert actor.ap_id <> "/followers" in like["to"]
    assert note_object.actor in like["to"]
  end

  test "EmojiReact.build/3 includes content and addressing" do
    {:ok, actor} = Users.create_local_user("alice")

    {:ok, note_object} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/2",
        type: "Note",
        actor: "https://remote.example/users/bob",
        object: nil,
        data: %{
          "id" => "https://remote.example/objects/2",
          "type" => "Note",
          "actor" => "https://remote.example/users/bob",
          "to" => [@public],
          "content" => "hello"
        },
        local: false
      })

    react = EmojiReact.build(actor, note_object, ":fire:")
    assert react["type"] == "EmojiReact"
    assert react["actor"] == actor.ap_id
    assert react["object"] == note_object.ap_id
    assert react["content"] == ":fire:"
    assert actor.ap_id <> "/followers" in react["to"]
    assert note_object.actor in react["to"]
  end

  test "Announce.build/2 includes public + followers + object actor addressing" do
    {:ok, actor} = Users.create_local_user("alice")

    {:ok, note_object} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/3",
        type: "Note",
        actor: "https://remote.example/users/bob",
        object: nil,
        data: %{
          "id" => "https://remote.example/objects/3",
          "type" => "Note",
          "actor" => "https://remote.example/users/bob",
          "to" => [@public],
          "content" => "hello"
        },
        local: false
      })

    announce = Announce.build(actor, note_object)
    assert announce["type"] == "Announce"
    assert announce["actor"] == actor.ap_id
    assert announce["object"] == note_object.ap_id
    assert @public in announce["to"]
    assert actor.ap_id <> "/followers" in announce["to"]
    assert note_object.actor in announce["to"]
  end

  test "Undo.build/2 copies addressing from the target activity when available" do
    {:ok, actor} = Users.create_local_user("alice")

    {:ok, announce_object} =
      Objects.create_object(%{
        ap_id: "https://local.example/activities/announce/1",
        type: "Announce",
        actor: actor.ap_id,
        object: "https://remote.example/objects/3",
        data: %{
          "id" => "https://local.example/activities/announce/1",
          "type" => "Announce",
          "actor" => actor.ap_id,
          "object" => "https://remote.example/objects/3",
          "to" => [@public],
          "cc" => [actor.ap_id <> "/followers"]
        },
        local: true
      })

    undo = Undo.build(actor, announce_object)
    assert undo["type"] == "Undo"
    assert undo["actor"] == actor.ap_id
    assert undo["object"] == announce_object.ap_id
    assert undo["to"] == [@public]
    assert undo["cc"] == [actor.ap_id <> "/followers"]
  end
end

