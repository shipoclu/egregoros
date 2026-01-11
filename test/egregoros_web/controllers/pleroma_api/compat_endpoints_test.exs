defmodule EgregorosWeb.PleromaAPI.CompatEndpointsTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users

  test "GET /api/pleroma/emoji.json returns custom emoji map", %{conn: conn} do
    conn = get(conn, "/api/pleroma/emoji.json")
    response = json_response(conn, 200)
    assert response == %{}
  end

  test "GET /api/v1/pleroma/emoji returns custom emoji map", %{conn: conn} do
    conn = get(conn, "/api/v1/pleroma/emoji")
    response = json_response(conn, 200)
    assert response == %{}
  end

  test "GET /api/v1/pleroma/accounts/:id/scrobbles returns empty list", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    conn = get(conn, "/api/v1/pleroma/accounts/#{user.id}/scrobbles", %{"limit" => "1"})
    response = json_response(conn, 200)
    assert response == []
  end

  test "GET /api/v1/pleroma/accounts/:id/favourites returns liked statuses", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    {:ok, note} =
      Pipeline.ingest(
        %{
          "id" => "https://remote.example/objects/liked-1",
          "type" => "Note",
          "actor" => "https://remote.example/users/bob",
          "content" => "Liked post",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["https://remote.example/users/bob/followers"]
        },
        local: false
      )

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Like",
               actor: user.ap_id,
               object: note.ap_id,
               activity_ap_id: "https://example.com/activities/like/1"
             })

    conn = get(conn, "/api/v1/pleroma/accounts/#{user.id}/favourites", %{"limit" => "20"})
    response = json_response(conn, 200)

    assert Enum.any?(response, &(&1["uri"] == note.ap_id))
  end
end

