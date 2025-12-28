defmodule EgregorosWeb.MastodonAPI.BlocksMutesControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.Relationships
  alias Egregoros.Users

  test "GET /api/v1/blocks returns blocked accounts", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")
    {:ok, blocked} = Users.create_local_user("blocked")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, _} =
      Relationships.upsert_relationship(%{
        type: "Block",
        actor: user.ap_id,
        object: blocked.ap_id,
        activity_ap_id: "https://example.com/activities/block/1"
      })

    conn = get(conn, "/api/v1/blocks")
    response = json_response(conn, 200)

    assert Enum.any?(response, &(&1["id"] == Integer.to_string(blocked.id)))
  end

  test "GET /api/v1/mutes returns muted accounts", %{conn: conn} do
    {:ok, user} = Users.create_local_user("local")
    {:ok, muted} = Users.create_local_user("muted")

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, user} end)

    {:ok, _} =
      Relationships.upsert_relationship(%{
        type: "Mute",
        actor: user.ap_id,
        object: muted.ap_id,
        activity_ap_id: "https://example.com/activities/mute/1"
      })

    conn = get(conn, "/api/v1/mutes")
    response = json_response(conn, 200)

    assert Enum.any?(response, &(&1["id"] == Integer.to_string(muted.id)))
  end
end

