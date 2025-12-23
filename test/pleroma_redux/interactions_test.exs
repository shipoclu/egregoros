defmodule PleromaRedux.InteractionsTest do
  use PleromaRedux.DataCase, async: true

  alias PleromaRedux.Interactions
  alias PleromaRedux.Objects
  alias PleromaRedux.Pipeline
  alias PleromaRedux.Users

  test "toggle_like refuses to like notes the user cannot view" do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, recipient} = Users.create_local_user("bob")

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://remote.example/objects/direct-like",
          "type" => "Note",
          "actor" => "https://remote.example/users/charlie",
          "content" => "Secret DM",
          "to" => [recipient.ap_id],
          "cc" => []
        },
        local: false
      )

    assert {:error, :not_found} = Interactions.toggle_like(user, note.id)
    refute Objects.get_by_type_actor_object("Like", user.ap_id, note.ap_id)
  end
end

