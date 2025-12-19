defmodule PleromaRedux.Federation.IncomingUndoFollowTest do
  use PleromaRedux.DataCase, async: true

  alias PleromaRedux.Objects
  alias PleromaRedux.Pipeline
  alias PleromaRedux.Users

  test "ingesting remote Undo of Follow removes the Follow object" do
    {:ok, local} = Users.create_local_user("alice")

    {:ok, remote} =
      Users.create_user(%{
        nickname: "bob",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    follow = %{
      "id" => "https://remote.example/activities/follow/undo-follow",
      "type" => "Follow",
      "actor" => remote.ap_id,
      "object" => local.ap_id
    }

    assert {:ok, _} = Pipeline.ingest(follow, local: false)
    assert Objects.get_by_ap_id(follow["id"])

    undo = %{
      "id" => "https://remote.example/activities/undo/undo-follow",
      "type" => "Undo",
      "actor" => remote.ap_id,
      "object" => follow["id"]
    }

    assert {:ok, _} = Pipeline.ingest(undo, local: false)

    assert Objects.get_by_ap_id(follow["id"]) == nil
    assert Objects.get_by_ap_id(undo["id"])
  end
end

