defmodule EgregorosWeb.MastodonAPI.FollowedTagsControllerTest do
  use EgregorosWeb.ConnCase, async: true

  import Mox

  alias Egregoros.Relationships
  alias Egregoros.Users

  test "GET /api/v1/followed_tags returns [] when the user does not follow any tags", %{
    conn: conn
  } do
    {:ok, user} = Users.create_local_user("local")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    assert conn |> get("/api/v1/followed_tags") |> json_response(200) == []
  end

  test "GET /api/v1/followed_tags returns normalized followed tags", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "FollowTag",
               actor: user.ap_id,
               object: "#Elixir",
               activity_ap_id: nil
             })

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    response = conn |> get("/api/v1/followed_tags") |> json_response(200)

    assert Enum.any?(response, &(&1["name"] == "elixir" and &1["following"] == true))
  end

  test "GET /api/v1/followed_tags ignores invalid tags, de-duplicates, and clamps limit", %{
    conn: conn
  } do
    {:ok, user} = Users.create_local_user("local")

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "FollowTag",
               actor: user.ap_id,
               object: "#elixir",
               activity_ap_id: nil
             })

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "FollowTag",
               actor: user.ap_id,
               object: "ELIXIR",
               activity_ap_id: nil
             })

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "FollowTag",
               actor: user.ap_id,
               object: "!!!!",
               activity_ap_id: nil
             })

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    response = conn |> get("/api/v1/followed_tags", %{"limit" => "999"}) |> json_response(200)

    assert [%{"name" => "elixir"}] = response
  end
end
