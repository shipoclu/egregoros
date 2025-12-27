defmodule EgregorosWeb.AdminControllerTest do
  use EgregorosWeb.ConnCase, async: true

  import Mox

  alias Egregoros.Federation.InternalFetchActor
  alias Egregoros.Relays
  alias Egregoros.Users
  alias Egregoros.Workers.DeliverActivity

  test "GET /admin redirects guests to login", %{conn: conn} do
    conn = get(conn, "/admin")
    assert redirected_to(conn) == "/login"
  end

  test "GET /admin rejects non-admins", %{conn: conn} do
    {:ok, user} = Users.create_local_user("bob")
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    conn = get(conn, "/admin")
    assert response(conn, 403) =~ "Forbidden"
  end

  test "GET /admin renders for admins", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    conn = get(conn, "/admin")
    html = html_response(conn, 200)
    assert html =~ "Admin settings"
    assert html =~ "Relays"
  end

  test "POST /admin/relays subscribes the internal actor to the relay", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, internal} = InternalFetchActor.get_actor()

    relay_ap_id = "https://relay.example/actor"
    relay_inbox = "https://relay.example/inbox"
    relay_outbox = "https://relay.example/outbox"

    expect(Egregoros.HTTP.Mock, :get, fn url, headers ->
      assert url == relay_ap_id
      assert List.keyfind(headers, "accept", 0)
      assert List.keyfind(headers, "user-agent", 0)

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => relay_ap_id,
           "type" => "Service",
           "preferredUsername" => "relay",
           "inbox" => relay_inbox,
           "outbox" => relay_outbox,
           "publicKey" => %{
             "id" => relay_ap_id <> "#main-key",
             "owner" => relay_ap_id,
             "publicKeyPem" => "-----BEGIN PUBLIC KEY-----\nMIIB\n-----END PUBLIC KEY-----"
           }
         },
         headers: []
       }}
    end)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    csrf_token = Phoenix.Controller.get_csrf_token()

    conn =
      post(conn, "/admin/relays", %{
        "_csrf_token" => csrf_token,
        "relay" => %{"ap_id" => relay_ap_id}
      })

    assert redirected_to(conn) == "/admin"
    assert Enum.any?(Relays.list_relays(), &(&1.ap_id == relay_ap_id))

    assert_enqueued(
      worker: DeliverActivity,
      args: %{
        "user_id" => internal.id,
        "inbox_url" => relay_inbox,
        "activity" => %{"type" => "Follow", "object" => relay_ap_id}
      }
    )
  end
end
