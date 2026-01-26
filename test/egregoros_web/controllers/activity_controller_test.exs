defmodule EgregorosWeb.ActivityControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.Pipeline
  alias Egregoros.Publish
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint

  test "GET /activities/:uuid returns stored activity as ActivityPub JSON", %{conn: conn} do
    {:ok, user} = Users.create_local_user("dana")
    uuid = Ecto.UUID.generate()
    public = "https://www.w3.org/ns/activitystreams#Public"

    note = %{
      "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
      "type" => "Note",
      "attributedTo" => user.ap_id,
      "to" => [public],
      "cc" => [user.ap_id <> "/followers"],
      "content" => "Hello from activities endpoint"
    }

    create = %{
      "id" => Endpoint.url() <> "/activities/" <> uuid,
      "type" => "Create",
      "actor" => user.ap_id,
      "to" => note["to"],
      "cc" => note["cc"],
      "object" => note
    }

    assert {:ok, _} = Pipeline.ingest(create, local: true, deliver: false)

    conn = get(conn, "/activities/#{uuid}")
    assert conn.status == 200

    [content_type] = get_resp_header(conn, "content-type")
    assert String.contains?(content_type, "application/activity+json")

    decoded = Jason.decode!(conn.resp_body)
    assert decoded["@context"] == "https://www.w3.org/ns/activitystreams"
    assert decoded["id"] == create["id"]
    assert decoded["type"] == "Create"
  end

  test "GET /activities/:type/:uuid returns stored typed activities", %{conn: conn} do
    {:ok, user} = Users.create_local_user("dana")
    {:ok, create} = Publish.post_note(user, "Hello world")

    %URI{path: path} = URI.parse(create.ap_id)
    ["activities", type, uuid] = String.split(path, "/", trim: true)

    conn = get(conn, "/activities/#{type}/#{uuid}")
    assert conn.status == 200

    decoded = Jason.decode!(conn.resp_body)
    assert decoded["@context"] == "https://www.w3.org/ns/activitystreams"
    assert decoded["id"] == create.ap_id
    assert decoded["type"] == "Create"
  end

  test "GET /activities/:type/:uuid does not serve direct messages", %{conn: conn} do
    {:ok, user} = Users.create_local_user("dana")

    {:ok, create} = Publish.post_note(user, "Secret DM", visibility: "direct")

    %URI{path: path} = URI.parse(create.ap_id)
    ["activities", type, uuid] = String.split(path, "/", trim: true)

    conn = get(conn, "/activities/#{type}/#{uuid}")
    assert response(conn, 404)
  end

  test "GET /activities/:uuid returns 404 when missing", %{conn: conn} do
    uuid = Ecto.UUID.generate()
    conn = get(conn, "/activities/#{uuid}")
    assert response(conn, 404)
  end
end
