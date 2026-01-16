defmodule EgregorosWeb.InstanceActorEndpointsTest do
  use EgregorosWeb.ConnCase, async: true

  alias EgregorosWeb.Endpoint

  test "GET /outbox returns an OrderedCollection", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/activity+json")
      |> get("/outbox")

    assert List.first(get_resp_header(conn, "content-type")) =~ "application/activity+json"

    body = Jason.decode!(response(conn, 200))
    assert body["id"] == Endpoint.url() <> "/outbox"
    assert body["type"] == "OrderedCollection"
  end
end
