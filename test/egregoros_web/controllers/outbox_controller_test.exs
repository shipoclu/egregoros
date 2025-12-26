defmodule EgregorosWeb.OutboxControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.Pipeline
  alias Egregoros.Users

  test "GET /users/:nickname/outbox returns ordered collection", %{conn: conn} do
    {:ok, user} = Users.create_local_user("ella")
    public = "https://www.w3.org/ns/activitystreams#Public"
    followers = user.ap_id <> "/followers"

    note = %{
      "id" => "https://example.com/objects/outbox-note",
      "type" => "Note",
      "attributedTo" => user.ap_id,
      "to" => [public],
      "cc" => [followers],
      "content" => "Outbox hello"
    }

    create = %{
      "id" => "https://example.com/activities/create/outbox-1",
      "type" => "Create",
      "actor" => user.ap_id,
      "to" => [public],
      "cc" => [followers],
      "object" => note
    }

    assert {:ok, _object} = Pipeline.ingest(create, local: true)

    conn = get(conn, "/users/ella/outbox")
    assert conn.status == 200

    [content_type] = get_resp_header(conn, "content-type")
    assert String.contains?(content_type, "application/activity+json")

    body = Jason.decode!(conn.resp_body)

    assert body["type"] == "OrderedCollection"
    assert Enum.any?(body["orderedItems"], &(&1["id"] == create["id"]))
  end

  test "GET /users/:nickname/outbox does not include direct messages", %{conn: conn} do
    {:ok, user} = Users.create_local_user("ella")
    public = "https://www.w3.org/ns/activitystreams#Public"
    followers = user.ap_id <> "/followers"

    public_note = %{
      "id" => "https://example.com/objects/outbox-public-note",
      "type" => "Note",
      "attributedTo" => user.ap_id,
      "to" => [public],
      "cc" => [followers],
      "content" => "Public hello"
    }

    public_create = %{
      "id" => "https://example.com/activities/create/outbox-public",
      "type" => "Create",
      "actor" => user.ap_id,
      "to" => [public],
      "cc" => [followers],
      "object" => public_note
    }

    direct_note = %{
      "id" => "https://example.com/objects/outbox-direct-note",
      "type" => "Note",
      "attributedTo" => user.ap_id,
      "to" => [],
      "cc" => [],
      "content" => "Secret DM"
    }

    direct_create = %{
      "id" => "https://example.com/activities/create/outbox-direct",
      "type" => "Create",
      "actor" => user.ap_id,
      "to" => [],
      "cc" => [],
      "object" => direct_note
    }

    assert {:ok, _} = Pipeline.ingest(public_create, local: true)
    assert {:ok, _} = Pipeline.ingest(direct_create, local: true)

    conn = get(conn, "/users/ella/outbox")
    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)

    assert Enum.any?(body["orderedItems"], &(&1["id"] == public_create["id"]))
    refute Enum.any?(body["orderedItems"], &(&1["id"] == direct_create["id"]))
  end
end
