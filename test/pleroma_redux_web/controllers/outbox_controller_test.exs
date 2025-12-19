defmodule PleromaReduxWeb.OutboxControllerTest do
  use PleromaReduxWeb.ConnCase, async: true

  alias PleromaRedux.Pipeline
  alias PleromaRedux.Users

  test "GET /users/:nickname/outbox returns ordered collection", %{conn: conn} do
    {:ok, user} = Users.create_local_user("ella")

    note = %{
      "id" => "https://example.com/objects/outbox-note",
      "type" => "Note",
      "attributedTo" => user.ap_id,
      "content" => "Outbox hello"
    }

    create = %{
      "id" => "https://example.com/activities/create/outbox-1",
      "type" => "Create",
      "actor" => user.ap_id,
      "object" => note
    }

    assert {:ok, _object} = Pipeline.ingest(create, local: true)

    conn = get(conn, "/users/ella/outbox")
    body = json_response(conn, 200)

    assert body["type"] == "OrderedCollection"
    assert Enum.any?(body["orderedItems"], &(&1["id"] == create["id"]))
  end
end
