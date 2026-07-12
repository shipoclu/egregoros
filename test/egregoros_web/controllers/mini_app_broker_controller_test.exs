defmodule EgregorosWeb.MiniAppBrokerControllerTest do
  use EgregorosWeb.ConnCase, async: false

  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.ResolvedCard
  alias Egregoros.Objects

  @public "https://www.w3.org/ns/activitystreams#Public"
  @launch_id "abcdefghijklmnopqrstuvwxyzABCDEFGH123456789"

  setup do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    :ok
  end

  test "serves a data-free broker with an exact app CSP and sandbox", %{conn: conn} do
    card = card_fixture()

    conn =
      get(
        conn,
        "/mini-apps/broker/#{card.id}?launch_id=#{@launch_id}&resolution_token=#{card.resolution_token}"
      )

    assert html_response(conn, 200) =~ ~s(id="mini-app-frame-root")
    assert conn.resp_body =~ ~s(data-launch-url="https://app.example/read/chapter-2")
    assert conn.resp_body =~ ~s(data-app-origin="https://app.example")
    refute conn.resp_body =~ "<iframe"
    refute conn.resp_body =~ "csrf"
    refute conn.resp_body =~ "mini-app-host-user"

    [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "default-src 'none'"
    assert policy =~ "frame-src https://app.example"
    assert policy =~ "frame-ancestors 'self'"
    refute policy =~ "frame-src https:;"
    assert get_resp_header(conn, "cache-control") == ["private, no-store, max-age=0"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end

  test "rejects stale cards and malformed launch identifiers", %{conn: conn} do
    card = card_fixture()

    assert response(
             get(
               conn,
               "/mini-apps/broker/#{card.id}?launch_id=short&resolution_token=#{card.resolution_token}"
             ),
             404
           )

    assert response(
             get(
               conn,
               "/mini-apps/broker/missing?launch_id=#{@launch_id}&resolution_token=#{card.resolution_token}"
             ),
             404
           )
  end

  test "requires the exact immutable card resolution token", %{conn: conn} do
    card = card_fixture()

    assert response(get(conn, "/mini-apps/broker/#{card.id}?launch_id=#{@launch_id}"), 404)

    assert response(
             get(
               conn,
               "/mini-apps/broker/#{card.id}?launch_id=#{@launch_id}&resolution_token=#{Ecto.UUID.generate()}"
             ),
             404
           )
  end

  test "rejects an app on the browser-visible session-cookie hostname at every port", %{
    conn: conn
  } do
    card = card_fixture("https://app.example:444")

    conn =
      conn
      |> Map.put(:host, "App.Example.")
      |> Map.put(:port, 443)

    assert response(
             get(
               conn,
               "/mini-apps/broker/#{card.id}?launch_id=#{@launch_id}&resolution_token=#{card.resolution_token}"
             ),
             404
           )
  end

  defp card_fixture(origin \\ "https://app.example") do
    {:ok, object} =
      Objects.create_object(%{
        ap_id: "https://social.example/notes/#{System.unique_integer([:positive])}",
        type: "Note",
        actor: "https://social.example/users/alice",
        data: %{"type" => "Note", "content" => "reader", "to" => [@public]}
      })

    manifest = %Manifest{
      version: "1",
      name: "Reader",
      origin: origin,
      home_url: origin <> "/",
      capabilities: [],
      cache_ttl_seconds: 600
    }

    resolved = %ResolvedCard{
      source_url: origin <> "/read/chapter-2",
      app_origin: origin,
      app_name: "Reader",
      title: "Reader",
      button_title: "Open",
      launch_url: origin <> "/read/chapter-2",
      image_url: nil,
      manifest: manifest
    }

    {:ok, card} = Cards.put(object, resolved)
    card
  end
end
