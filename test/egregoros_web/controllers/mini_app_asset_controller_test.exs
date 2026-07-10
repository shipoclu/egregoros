defmodule EgregorosWeb.MiniAppAssetControllerTest do
  use EgregorosWeb.ConnCase, async: false

  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.ResolvedCard
  alias Egregoros.Objects

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    previous_enabled = Application.get_env(:egregoros, :mini_apps_enabled, false)
    Application.put_env(:egregoros, :mini_apps_enabled, true)
    on_exit(fn -> Application.put_env(:egregoros, :mini_apps_enabled, previous_enabled) end)
    enable_mini_apps()
    :ok
  end

  test "proxies a card image without persistent or shared caching", %{conn: conn} do
    card = card_fixture("https://app.example/card.png")
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/card.png", :asset ->
        {:ok, %{status: 200, body: png, headers: [{"content-type", "image/png"}]}}
    end)

    conn = get(conn, "/mini-app-assets/#{card.id}/image")

    assert conn.status == 200
    assert conn.resp_body == png
    assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store, max-age=0"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "does not become an arbitrary image proxy", %{conn: conn} do
    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("unknown card IDs must not trigger fetches")
    end)

    conn = get(conn, "/mini-app-assets/#{Ecto.UUID.generate()}/image")
    assert response(conn, 404)
  end

  test "returns a generic gateway error without exposing fetch details", %{conn: conn} do
    card = card_fixture("https://app.example/card.png")

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/card.png", :asset -> {:error, :timeout}
    end)

    conn = get(conn, "/mini-app-assets/#{card.id}/image")
    assert response(conn, 502) == "Unable to load image"
    assert get_resp_header(conn, "cache-control") == ["private, no-store, max-age=0"]
  end

  defp card_fixture(image_url) do
    {:ok, object} =
      Objects.create_object(%{
        ap_id: "https://social.example/notes/#{System.unique_integer([:positive])}",
        type: "Note",
        actor: "https://social.example/users/alice",
        data: %{
          "type" => "Note",
          "content" => "reader",
          "to" => [@public]
        }
      })

    manifest = %Manifest{
      version: "1",
      name: "Reader",
      origin: "https://app.example",
      home_url: "https://app.example/",
      capabilities: [],
      cache_ttl_seconds: 600
    }

    resolved = %ResolvedCard{
      source_url: "https://app.example/read",
      app_origin: "https://app.example",
      app_name: "Reader",
      title: "Reader",
      button_title: "Open",
      launch_url: "https://app.example/read",
      image_url: image_url,
      manifest: manifest
    }

    {:ok, card} = Cards.put(object, resolved)
    card
  end

  defp enable_mini_apps do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)
  end
end
