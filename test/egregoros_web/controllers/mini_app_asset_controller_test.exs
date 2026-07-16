defmodule EgregorosWeb.MiniAppAssetControllerTest do
  use EgregorosWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Egregoros.MiniApps.Card
  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.DeveloperLaunches
  alias Egregoros.MiniApps.ImageCache
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.ResolvedCard
  alias Egregoros.Objects
  alias Egregoros.Repo
  alias Egregoros.Users

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    previous_enabled = Application.get_env(:egregoros, :mini_apps_enabled, false)
    Application.put_env(:egregoros, :mini_apps_enabled, true)
    on_exit(fn -> Application.put_env(:egregoros, :mini_apps_enabled, previous_enabled) end)
    enable_mini_apps()
    :ok = ImageCache.clear()

    safe_webp = image_binary(3, 2, ".webp")

    stub(Egregoros.MiniApps.ImageSanitizer.Mock, :sanitize, fn
      _body, "image/png" ->
        {:ok, %{body: safe_webp, content_type: "image/webp"}}

      _body, _content_type ->
        {:error, :invalid_image}
    end)

    :ok
  end

  test "proxies and caches a sanitized card image by exact resolution", %{conn: conn} do
    card = card_fixture("https://app.example/card.png")
    png = image_binary(3, 2, ".png")

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/card.png", :asset ->
        {:ok, %{status: 200, body: png, headers: [{"content-type", "image/png"}]}}
    end)

    path =
      "/mini-app-assets/#{card.id}/image?resolution_token=#{card.resolution_token}"

    first_conn =
      get(
        conn,
        path
      )

    second_conn = get(conn, path)

    for response_conn <- [first_conn, second_conn] do
      assert response_conn.status == 200
      refute response_conn.resp_body == png
      assert <<"RIFF", _size::little-32, "WEBP", _rest::binary>> = response_conn.resp_body
      assert get_resp_header(response_conn, "content-type") == ["image/webp"]
      assert get_resp_header(response_conn, "cache-control") == ["private, max-age=300"]
      assert get_resp_header(response_conn, "pragma") == []
      assert get_resp_header(response_conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(response_conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(response_conn, "cross-origin-resource-policy") == ["same-origin"]

      assert get_resp_header(response_conn, "content-security-policy") == [
               "default-src 'none'; sandbox"
             ]

      assert get_resp_header(response_conn, "set-cookie") == []
    end
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

  test "logs fetch failures while returning a generic gateway error", %{conn: conn} do
    card = card_fixture("https://app.example/card.png")

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/card.png", :asset -> {:error, :timeout}
    end)

    log =
      capture_log(fn ->
        conn =
          get(
            conn,
            "/mini-app-assets/#{card.id}/image?resolution_token=#{card.resolution_token}"
          )

        assert response(conn, 502) == "Unable to load image"
        assert get_resp_header(conn, "cache-control") == ["private, no-store, max-age=0"]
      end)

    assert log =~ "mini-app image delivery failed"
    assert log =~ "stage=:fetch"
    assert log =~ "card_id=#{inspect(card.id)}"
    assert log =~ ~s(target="https://app.example/card.png")
    assert log =~ "reason=:timeout"
  end

  test "rejects MIME-spoofed or undecodable images without reflecting remote bytes", %{conn: conn} do
    card = card_fixture("https://app.example/card.jpg")
    png = image_binary(2, 2, ".png")

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/card.jpg", :asset ->
        {:ok, %{status: 200, body: png, headers: [{"content-type", "image/jpeg"}]}}
    end)

    log =
      capture_log(fn ->
        conn =
          get(
            conn,
            "/mini-app-assets/#{card.id}/image?resolution_token=#{card.resolution_token}"
          )

        assert response(conn, 502) == "Unable to load image"
        refute conn.resp_body =~ png
        assert get_resp_header(conn, "cache-control") == ["private, no-store, max-age=0"]
      end)

    assert log =~ "stage=:sanitize"
    assert log =~ "reason=:invalid_image"
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

  test "rechecks card activity before serving a sanitized cache hit", %{conn: conn} do
    card = card_fixture("https://app.example/card.png")
    png = image_binary(3, 2, ".png")

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/card.png", :asset ->
        {:ok, %{status: 200, body: png, headers: [{"content-type", "image/png"}]}}
    end)

    path = "/mini-app-assets/#{card.id}/image?resolution_token=#{card.resolution_token}"

    assert conn |> get(path) |> response(200)
    Repo.delete!(card)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("an inactive cached card must not trigger another fetch")
    end)

    assert conn |> get(path) |> response(404) == "Not found"
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

  test "proxies developer-card images only for their exact opted-in session", %{conn: conn} do
    {:ok, owner} = Users.create_local_user("asset-developer-owner")
    {:ok, owner} = Users.update_profile(owner, %{"developer_mode" => true})
    {:ok, other} = Users.create_local_user("asset-developer-other")
    {:ok, other} = Users.update_profile(other, %{"developer_mode" => true})
    {:ok, card} = DeveloperLaunches.put(owner, resolved_card("https://app.example/card.png"))
    png = image_binary(3, 2, ".png")

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/card.png", :asset ->
        {:ok, %{status: 200, body: png, headers: [{"content-type", "image/png"}]}}
    end)

    path = "/mini-app-assets/#{card.id}/image?resolution_token=#{card.resolution_token}"

    assert conn
           |> Plug.Test.init_test_session(%{user_id: owner.id})
           |> get(path)
           |> response(200)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("another user's diagnostic card must not trigger a fetch")
    end)

    assert conn
           |> Plug.Test.init_test_session(%{user_id: other.id})
           |> get(path)
           |> response(404)
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

    {:ok, card} = Cards.put(object, resolved_card(image_url))
    card
  end

  defp resolved_card(image_url) do
    manifest = %Manifest{
      version: "1",
      name: "Reader",
      origin: "https://app.example",
      home_url: "https://app.example/",
      capabilities: [],
      cache_ttl_seconds: 600
    }

    %ResolvedCard{
      source_url: "https://app.example/read",
      app_origin: "https://app.example",
      app_name: "Reader",
      title: "Reader",
      button_title: "Open",
      launch_url: "https://app.example/read",
      image_url: image_url,
      manifest: manifest
    }
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
