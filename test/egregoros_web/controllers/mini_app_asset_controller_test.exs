defmodule EgregorosWeb.MiniAppAssetControllerTest do
  use EgregorosWeb.ConnCase, async: false

  alias Egregoros.MiniApps.Card
  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.ResolvedCard
  alias Egregoros.Objects
  alias Egregoros.Repo

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    previous_enabled = Application.get_env(:egregoros, :mini_apps_enabled, false)
    Application.put_env(:egregoros, :mini_apps_enabled, true)
    on_exit(fn -> Application.put_env(:egregoros, :mini_apps_enabled, previous_enabled) end)
    enable_mini_apps()

    safe_webp = image_binary(3, 2, ".webp")

    stub(Egregoros.MiniApps.ImageSanitizer.Mock, :sanitize, fn
      _body, "image/png" ->
        {:ok, %{body: safe_webp, content_type: "image/webp"}}

      _body, _content_type ->
        {:error, :invalid_image}
    end)

    :ok
  end

  test "proxies a card image without persistent or shared caching", %{conn: conn} do
    card = card_fixture("https://app.example/card.png")
    png = image_binary(3, 2, ".png")

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/card.png", :asset ->
        {:ok, %{status: 200, body: png, headers: [{"content-type", "image/png"}]}}
    end)

    conn =
      get(
        conn,
        "/mini-app-assets/#{card.id}/image?resolution_token=#{card.resolution_token}"
      )

    assert conn.status == 200
    refute conn.resp_body == png
    assert <<"RIFF", _size::little-32, "WEBP", _rest::binary>> = conn.resp_body
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store, max-age=0"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "cross-origin-resource-policy") == ["same-origin"]
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "does not become an arbitrary image proxy", %{conn: conn} do
    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("unknown card IDs must not trigger fetches")
    end)

    conn =
      get(
        conn,
        "/mini-app-assets/#{Ecto.UUID.generate()}/image?resolution_token=#{Ecto.UUID.generate()}"
      )

    assert response(conn, 404)
  end

  test "rejects a token from a different card resolution without fetching", %{conn: conn} do
    card = card_fixture("https://app.example/card.png")

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("mismatched card resolutions must not trigger fetches")
    end)

    conn =
      get(
        conn,
        "/mini-app-assets/#{card.id}/image?resolution_token=#{Ecto.UUID.generate()}"
      )

    assert response(conn, 404)
  end

  test "returns a generic gateway error without exposing fetch details", %{conn: conn} do
    card = card_fixture("https://app.example/card.png")

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/card.png", :asset -> {:error, :timeout}
    end)

    conn =
      get(
        conn,
        "/mini-app-assets/#{card.id}/image?resolution_token=#{card.resolution_token}"
      )

    assert response(conn, 502) == "Unable to load image"
    assert get_resp_header(conn, "cache-control") == ["private, no-store, max-age=0"]
  end

  test "rejects MIME-spoofed or undecodable images without reflecting remote bytes", %{conn: conn} do
    card = card_fixture("https://app.example/card.jpg")
    png = image_binary(2, 2, ".png")

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/card.jpg", :asset ->
        {:ok, %{status: 200, body: png, headers: [{"content-type", "image/jpeg"}]}}
    end)

    conn =
      get(
        conn,
        "/mini-app-assets/#{card.id}/image?resolution_token=#{card.resolution_token}"
      )

    assert response(conn, 502) == "Unable to load image"
    refute conn.resp_body =~ png
    assert get_resp_header(conn, "cache-control") == ["private, no-store, max-age=0"]
  end

  test "rechecks the immediate domain policy before proxying a stored card", %{conn: conn} do
    card = card_fixture("https://app.example/card.png")

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> ["app.example"]
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("a newly denied image origin must not be fetched")
    end)

    conn =
      get(
        conn,
        "/mini-app-assets/#{card.id}/image?resolution_token=#{card.resolution_token}"
      )

    assert response(conn, 404) == "Not found"
  end

  test "does not send fetched bytes after the card is deleted", %{conn: conn} do
    card = card_fixture("https://app.example/card.png")

    conn =
      request_while_fetch_is_paused(conn, card, fn ->
        Repo.delete!(card)
      end)

    assert response(conn, 404) == "Not found"
  end

  test "does not send fetched bytes after the exact card resolution changes", %{conn: conn} do
    card = card_fixture("https://app.example/card.png")

    conn =
      request_while_fetch_is_paused(conn, card, fn ->
        card
        |> Ecto.Changeset.change(resolution_token: Ecto.UUID.generate())
        |> Repo.update!()
      end)

    assert response(conn, 404) == "Not found"
  end

  test "does not send fetched bytes when the origin is denied during the fetch", %{conn: conn} do
    card = card_fixture("https://app.example/card.png")
    previous_denylist = Application.get_env(:egregoros, :mini_apps_domain_denylist, [])

    on_exit(fn ->
      Application.put_env(:egregoros, :mini_apps_domain_denylist, previous_denylist)
    end)

    conn =
      request_while_fetch_is_paused(conn, card, fn ->
        Application.put_env(:egregoros, :mini_apps_domain_denylist, ["app.example"])
      end)

    assert response(conn, 404) == "Not found"
  end

  test "rate limits asset proxy requests by trustworthy client address", %{conn: conn} do
    card = card_fixture("https://app.example/card.png")

    expect(Egregoros.RateLimiter.Mock, :allow?, fn
      :mini_app_asset_ip, "127.0.0.1", 60, 60_000 -> {:error, :rate_limited}
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("rate-limited requests must not fetch remote bytes")
    end)

    conn =
      get(
        conn,
        "/mini-app-assets/#{card.id}/image?resolution_token=#{card.resolution_token}"
      )

    assert response(conn, 429) == "Too many requests"
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

  defp request_while_fetch_is_paused(conn, %Card{} = card, mutate) do
    parent = self()
    continue_ref = make_ref()
    result_ref = make_ref()
    png = image_binary(3, 2, ".png")

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn url, :asset ->
      assert url == card.image_url
      send(parent, {:asset_fetch_paused, self(), continue_ref})

      receive do
        {:continue_asset_fetch, ^continue_ref} ->
          {:ok, %{status: 200, body: png, headers: [{"content-type", "image/png"}]}}
      end
    end)

    request_pid =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             receive do
               {:start_asset_request, ^result_ref} ->
                 result =
                   get(
                     conn,
                     "/mini-app-assets/#{card.id}/image?resolution_token=#{card.resolution_token}"
                   )

                 send(parent, {:asset_request_result, result_ref, result})
             end
           end},
          id: {:asset_request, result_ref},
          restart: :temporary
        )
      )

    :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), request_pid)
    Mox.allow(Egregoros.MiniApps.ImageSanitizer.Mock, self(), request_pid)
    monitor_ref = Process.monitor(request_pid)
    send(request_pid, {:start_asset_request, result_ref})

    assert_receive {:asset_fetch_paused, ^request_pid, ^continue_ref}
    mutate.()
    send(request_pid, {:continue_asset_fetch, continue_ref})

    assert_receive {:asset_request_result, ^result_ref, result}, 5_000
    assert_receive {:DOWN, ^monitor_ref, :process, ^request_pid, :normal}, 5_000
    result
  end

  defp image_binary(width, height, suffix) do
    {:ok, image} = Image.new(width, height, color: :blue)
    {:ok, body} = Image.write(image, :memory, suffix: suffix, strip_metadata: true)
    body
  end
end
