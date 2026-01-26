defmodule EgregorosWeb.MastodonAPI.FavouritesAndBookmarksControllerTest do
  use EgregorosWeb.ConnCase, async: true

  import Mox

  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users

  @public "https://www.w3.org/ns/activitystreams#Public"

  test "GET /api/v1/favourites returns statuses the user has favourited", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, _} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/like-me",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Hello like",
          "to" => [@public],
          "cc" => ["https://example.com/users/alice/followers"]
        },
        local: false
      )

    [object] = Objects.list_notes()

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Like",
               actor: user.ap_id,
               object: object.ap_id,
               activity_ap_id: "https://egregoros.example/activities/like/1"
             })

    response = conn |> get("/api/v1/favourites") |> json_response(200)

    assert [%{} = status] = response
    assert status["id"] == object.id
    assert status["favourited"] == true
  end

  test "GET /api/v1/bookmarks returns statuses the user has bookmarked", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, _} =
      Pipeline.ingest(
        %{
          "id" => "https://example.com/objects/bookmark-me",
          "type" => "Note",
          "actor" => "https://example.com/users/alice",
          "content" => "Hello bookmark",
          "to" => [@public],
          "cc" => ["https://example.com/users/alice/followers"]
        },
        local: false
      )

    [object] = Objects.list_notes()

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "Bookmark",
               actor: user.ap_id,
               object: object.ap_id
             })

    response = conn |> get("/api/v1/bookmarks") |> json_response(200)

    assert [%{} = status] = response
    assert status["id"] == object.id
    assert status["bookmarked"] == true
  end
end
