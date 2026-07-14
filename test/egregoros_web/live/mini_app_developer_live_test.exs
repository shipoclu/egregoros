defmodule EgregorosWeb.MiniAppDeveloperLiveTest do
  use EgregorosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Egregoros.Users

  @origin "https://app.example"
  @url @origin <> "/reader"
  @manifest_url @origin <> "/.well-known/fediverse-miniapp.json"
  @host_origin "https://social.example"

  setup do
    Mox.set_mox_global()

    previous_enabled = Application.get_env(:egregoros, :mini_apps_enabled, false)
    Application.put_env(:egregoros, :mini_apps_enabled, true)

    on_exit(fn ->
      Application.put_env(:egregoros, :mini_apps_enabled, previous_enabled)
    end)

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    :ok
  end

  test "requires login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/developer/mini-apps")
  end

  test "requires the developer preference", %{conn: conn} do
    {:ok, user} = Users.create_local_user("developer-disabled")
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    assert {:error, {:redirect, %{to: "/settings"}}} = live(conn, "/developer/mini-apps")
  end

  test "renders for a user who enabled developer mode", %{conn: conn} do
    {:ok, user} = Users.create_local_user("developer-enabled")
    {:ok, user} = Users.update_profile(user, %{"developer_mode" => true})
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, "/developer/mini-apps")

    assert has_element?(view, "[data-role='mini-app-developer']")
    assert has_element?(view, "[data-role='nav-developer'][aria-current='page']")
  end

  test "runs server checks, renders the rich card, and completes on ready", %{conn: conn} do
    {:ok, user} = Users.create_local_user("developer-conformance-pass")
    {:ok, user} = Users.update_profile(user, %{"developer_mode" => true})
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    expect_valid_fetches()

    {:ok, view, _html} = live(conn, "/developer/mini-apps")
    set_host_origin(view, @host_origin)

    view
    |> form("#mini-app-diagnostic-form", probe: %{url: @url})
    |> render_submit()

    render_async(view)

    assert has_element?(view, "#mini-app-diagnostic-results")
    assert has_element?(view, "#mini-app-diagnostic-preview")

    assert has_element?(
             view,
             "#mini-app-diagnostic-overall-status[data-status='pending']",
             "Incomplete"
           )

    assert has_element?(
             view,
             "#mini-app-diagnostic-check-manifest_parse[data-status='pass'][data-requirement='required']"
           )

    assert has_element?(view, "#mini-app-diagnostic-check-ready[data-status='not_run']")

    assert has_element?(
             view,
             "#mini-app-diagnostic-ready-availability[data-available='true']",
             "safe launch card"
           )

    assert has_element?(view, "#mini-app-diagnostic-ready-availability", "other required")
    assert has_element?(view, "[data-role='mini-app-launch-disclosure']", "synthetic")
    assert has_element?(view, "[data-role='mini-app-launch-disclosure']", "does not claim")

    view |> element("#developer-mini-app-card-open") |> render_click()

    state = :sys.get_state(view.pid).socket.assigns.mini_app_host
    assert state.card.developer_user_id == user.id
    assert state.launch_info["linkedUrl"] == @url
    assert state.launch_info["sourceNoteId"] =~ "/developer/mini-apps"
    assert has_element?(view, "#mini-app-diagnostic-check-ready[data-status='pending']")

    render_hook(view, "mini_app_ready", %{"launch_id" => state.launch_id})

    assert has_element?(
             view,
             "#mini-app-diagnostic-overall-status[data-status='pass']",
             "Passed"
           )

    assert has_element?(view, "#mini-app-diagnostic-check-ready[data-status='pass']")
  end

  test "reports an early required failure without creating a launchable proxy card", %{conn: conn} do
    {:ok, user} = Users.create_local_user("developer-conformance-fail")
    {:ok, user} = Users.update_profile(user, %{"developer_mode" => true})
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn @manifest_url, :manifest ->
      {:error, :timeout}
    end)

    {:ok, view, _html} = live(conn, "/developer/mini-apps")
    set_host_origin(view, @host_origin)

    view
    |> form("#mini-app-diagnostic-form", probe: %{url: @url})
    |> render_submit()

    render_async(view)

    assert has_element?(
             view,
             "#mini-app-diagnostic-overall-status[data-status='fail']",
             "Failed"
           )

    assert has_element?(view, "#mini-app-diagnostic-check-manifest_fetch[data-status='fail']")
    assert has_element?(view, "#mini-app-diagnostic-check-ready[data-status='fail']")

    assert has_element?(
             view,
             "#mini-app-diagnostic-ready-availability[data-available='false']",
             "early required"
           )

    refute has_element?(view, "#mini-app-diagnostic-preview")
  end

  test "rate limits diagnostic starts before fetching a remote URL", %{conn: conn} do
    {:ok, user} = Users.create_local_user("developer-conformance-limited")
    {:ok, user} = Users.update_profile(user, %{"developer_mode" => true})
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    expect(Egregoros.RateLimiter.Mock, :allow?, fn
      :mini_app_developer_probe, user_id, 5, 60_000 when user_id == user.id ->
        {:error, :rate_limited}
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, 0, fn _url, _kind ->
      flunk("rate-limited diagnostics must not fetch")
    end)

    {:ok, view, _html} = live(conn, "/developer/mini-apps")

    view
    |> form("#mini-app-diagnostic-form", probe: %{url: @url})
    |> render_submit()

    assert render(view) =~ "Too many diagnostic requests"
    refute has_element?(view, "#mini-app-diagnostic-running")
  end

  defp expect_valid_fetches do
    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn @manifest_url, :manifest ->
      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "version" => "1",
             "name" => "Reader",
             "homeUrl" => @url,
             "capabilities" => []
           }),
         headers: replace_header(good_headers(), "content-type", "application/json")
       }}
    end)

    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn @url, :page ->
      {:ok,
       %{
         status: 200,
         body: "<html><body>Reader</body></html>",
         headers: good_headers()
       }}
    end)
  end

  defp good_headers do
    [
      {"content-type", "text/html; charset=utf-8"},
      {"content-security-policy",
       "default-src 'self'; object-src 'none'; frame-ancestors #{@host_origin}"},
      {"x-content-type-options", "nosniff"},
      {"referrer-policy", "no-referrer"},
      {"permissions-policy",
       "camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=(), bluetooth=(), hid=(), midi=(), display-capture=()"},
      {"strict-transport-security", "max-age=31536000"}
    ]
  end

  defp replace_header(headers, name, value) do
    [{name, value} | Enum.reject(headers, fn {key, _value} -> key == name end)]
  end

  defp set_host_origin(view, origin) do
    :sys.replace_state(view.pid, fn state ->
      put_in(state.socket.assigns.host_origin, origin)
    end)
  end
end
