defmodule PleromaRedux.RelationshipsTest do
  use PleromaRedux.DataCase, async: true

  alias PleromaRedux.Pipeline
  alias PleromaRedux.Relationships
  alias PleromaRedux.Users

  test "ingesting multiple Follow activities produces a single relationship state" do
    {:ok, local} = Users.create_local_user("alice")

    remote_actor = "https://remote.example/users/bob"

    follow_1 = %{
      "id" => "https://remote.example/activities/follow/1",
      "type" => "Follow",
      "actor" => remote_actor,
      "object" => local.ap_id
    }

    follow_2 = %{
      "id" => "https://remote.example/activities/follow/2",
      "type" => "Follow",
      "actor" => remote_actor,
      "object" => local.ap_id
    }

    assert {:ok, _} = Pipeline.ingest(follow_1, local: false)
    assert {:ok, _} = Pipeline.ingest(follow_2, local: false)

    assert [relationship] = Relationships.list_follows_to(local.ap_id)
    assert relationship.actor == remote_actor
    assert relationship.object == local.ap_id
    assert relationship.activity_ap_id == follow_2["id"]
  end

  test "Undo of an older Follow does not remove the current follow relationship state" do
    {:ok, local} = Users.create_local_user("alice")

    remote_actor = "https://remote.example/users/bob"

    follow_1 = %{
      "id" => "https://remote.example/activities/follow/1",
      "type" => "Follow",
      "actor" => remote_actor,
      "object" => local.ap_id
    }

    follow_2 = %{
      "id" => "https://remote.example/activities/follow/2",
      "type" => "Follow",
      "actor" => remote_actor,
      "object" => local.ap_id
    }

    assert {:ok, _} = Pipeline.ingest(follow_1, local: false)
    assert {:ok, _} = Pipeline.ingest(follow_2, local: false)

    undo_1 = %{
      "id" => "https://remote.example/activities/undo/1",
      "type" => "Undo",
      "actor" => remote_actor,
      "object" => follow_1["id"]
    }

    assert {:ok, _} = Pipeline.ingest(undo_1, local: false)

    assert [relationship] = Relationships.list_follows_to(local.ap_id)
    assert relationship.activity_ap_id == follow_2["id"]
  end

  test "Undo of the latest Follow removes the follow relationship state" do
    {:ok, local} = Users.create_local_user("alice")

    remote_actor = "https://remote.example/users/bob"

    follow_1 = %{
      "id" => "https://remote.example/activities/follow/1",
      "type" => "Follow",
      "actor" => remote_actor,
      "object" => local.ap_id
    }

    follow_2 = %{
      "id" => "https://remote.example/activities/follow/2",
      "type" => "Follow",
      "actor" => remote_actor,
      "object" => local.ap_id
    }

    assert {:ok, _} = Pipeline.ingest(follow_1, local: false)
    assert {:ok, _} = Pipeline.ingest(follow_2, local: false)

    undo_2 = %{
      "id" => "https://remote.example/activities/undo/2",
      "type" => "Undo",
      "actor" => remote_actor,
      "object" => follow_2["id"]
    }

    assert {:ok, _} = Pipeline.ingest(undo_2, local: false)

    assert [] == Relationships.list_follows_to(local.ap_id)
  end
end
