defmodule EgregorosWeb.RootActorTest do
  use EgregorosWeb.ConnCase, async: true

  alias EgregorosWeb.Endpoint

  test "GET / serves the instance actor for ActivityPub requests", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/activity+json")
      |> get("/")

    assert List.first(get_resp_header(conn, "content-type")) =~ "application/activity+json"
    assert List.first(get_resp_header(conn, "vary")) =~ "accept"

    body = Jason.decode!(response(conn, 200))

    assert body["id"] == Endpoint.url()
    assert body["type"] == "Application"
    assert body["inbox"] == Endpoint.url() <> "/inbox"

    assert body["publicKey"]["id"] == Endpoint.url() <> "#main-key"
    assert body["publicKey"]["owner"] == Endpoint.url()
  end
end
