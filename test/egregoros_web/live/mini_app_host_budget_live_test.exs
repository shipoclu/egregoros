defmodule EgregorosWeb.MiniAppHostBudgetLiveTest do
  use EgregorosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Egregoros.Activities.Note
  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.ContextConsents
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.ResolvedCard
  alias Egregoros.Pipeline
  alias Egregoros.Timeline
  alias Egregoros.Users

  setup do
    Timeline.reset()
    previous_enabled = Application.get_env(:egregoros, :mini_apps_enabled, false)
    on_exit(fn -> Application.put_env(:egregoros, :mini_apps_enabled, previous_enabled) end)
    Application.put_env(:egregoros, :mini_apps_enabled, true)

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    {:ok, user} = Users.create_local_user("mini-app-budget-user")
    %{user: user}
  end

  test "a second context request cannot replace the request visible to the user", %{
    conn: conn,
    user: user
  } do
    {view, launch_id} = open_ready_app(conn, user)

    render_hook(view, "mini_app_context_request", %{
      "launch_id" => launch_id,
      "request_id" => "ctx-original"
    })

    render_hook(view, "mini_app_context_request", %{
      "launch_id" => launch_id,
      "request_id" => "ctx-smuggled"
    })

    assert %{request_id: "ctx-original"} =
             :sys.get_state(view.pid).socket.assigns.mini_app_host.context_request

    view |> element("#mini-app-context-approve") |> render_click()

    assert_push_event(view, "mini_app_context_response", %{
      launch_id: ^launch_id,
      request_id: "ctx-original",
      status: "ok",
      context: %{}
    })
  end

  test "server closes a launch that exceeds its event rate budget", %{conn: conn, user: user} do
    {view, launch_id} = open_ready_app(conn, user)
    assert {:ok, _consent} = ContextConsents.grant(user.id, "https://app.example")

    for index <- 1..80 do
      render_hook(view, "mini_app_context_request", %{
        "launch_id" => launch_id,
        "request_id" => "ctx-#{index}"
      })
    end

    assert has_element?(view, "#mini-app-host[data-state='closed']")
  end

  test "server closes a launch before dispatching an oversized broker event", %{
    conn: conn,
    user: user
  } do
    {view, launch_id} = open_ready_app(conn, user)

    render_hook(view, "mini_app_context_request", %{
      "launch_id" => launch_id,
      "request_id" => "ctx-oversized",
      "padding" => String.duplicate("x", 400_000)
    })

    assert has_element?(view, "#mini-app-host[data-state='closed']")
    refute has_element?(view, "#mini-app-context-consent")
  end

  test "server closes a launch when cumulative broker payload exceeds its byte budget", %{
    conn: conn,
    user: user
  } do
    {view, launch_id} = open_ready_app(conn, user)
    assert {:ok, _consent} = ContextConsents.grant(user.id, "https://app.example")

    for index <- 1..6 do
      render_hook(view, "mini_app_context_request", %{
        "launch_id" => launch_id,
        "request_id" => "ctx-total-#{index}",
        "padding" => String.duplicate("x", 350_000)
      })
    end

    assert has_element?(view, "#mini-app-host[data-state='closed']")
  end

  defp open_ready_app(conn, user) do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/chapter-2">reader</a>)),
        local: true
      )

    assert {:ok, _card} = Cards.put(note, resolved_card())
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")
    view |> element("[data-role='open-mini-app']") |> render_click()
    launch_id = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id
    render_hook(view, "mini_app_ready", %{"launch_id" => launch_id})
    {view, launch_id}
  end

  defp resolved_card do
    manifest = %Manifest{
      version: "1",
      name: "Reader",
      origin: "https://app.example",
      home_url: "https://app.example/",
      capabilities: [],
      cache_ttl_seconds: 600
    }

    %ResolvedCard{
      source_url: "https://app.example/shared/chapter-2",
      app_origin: "https://app.example",
      app_name: "Reader",
      title: "Chapter 2",
      button_title: "Read",
      launch_url: "https://app.example/book/chapter-2",
      image_url: "https://app.example/card.png",
      manifest: manifest
    }
  end
end
