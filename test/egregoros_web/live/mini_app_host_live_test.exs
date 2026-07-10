defmodule EgregorosWeb.MiniAppHostLiveTest do
  use EgregorosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Egregoros.Activities.Note
  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.ResolvedCard
  alias Egregoros.Pipeline
  alias Egregoros.Timeline
  alias Egregoros.Users

  setup do
    Timeline.reset()
    previous_enabled = Application.get_env(:egregoros, :mini_apps_enabled, false)
    on_exit(fn -> Application.put_env(:egregoros, :mini_apps_enabled, previous_enabled) end)
    enable_mini_apps()
    {:ok, user} = Users.create_local_user("mini-app-host-user")
    %{user: user}
  end

  test "opens only a trusted cached card and supports collapse, expand, and close", %{
    conn: conn,
    user: user
  } do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/chapter-2">reader</a>)),
        local: true
      )

    assert {:ok, card} = Cards.put(note, resolved_card())
    assert Cards.get_active(note)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")

    assert has_element?(view, "[data-role='status-card']")
    assert has_element?(view, "[data-role='mini-app-card']")
    refute has_element?(view, "#mini-app-host[data-state='open']")

    view |> element("[data-role='open-mini-app']") |> render_click()

    assert has_element?(view, "#mini-app-host[data-state='open']")

    assert has_element?(
             view,
             ~s(#mini-app-host iframe[src="https://app.example/book/chapter-2"][sandbox="allow-scripts allow-forms allow-same-origin"])
           )

    assert has_element?(view, "#mini-app-host[data-app-origin='https://app.example']")
    assert has_element?(view, "#mini-app-host[phx-hook='MiniAppHost']")
    assert has_element?(view, "#mini-app-host [data-role='mini-app-loading']")

    launch_id = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id

    render_hook(view, "mini_app_ready", %{"launch_id" => "wrong"})
    assert has_element?(view, "#mini-app-host [data-role='mini-app-loading']")

    render_hook(view, "mini_app_ready", %{"launch_id" => launch_id})
    refute has_element?(view, "#mini-app-host [data-role='mini-app-loading']")

    render_hook(view, "mini_app_context_request", %{
      "launch_id" => launch_id,
      "request_id" => "ctx-1"
    })

    assert has_element?(view, "#mini-app-context-consent")
    assert has_element?(view, "#mini-app-context-consent", "app.example")

    view |> element("#mini-app-context-approve") |> render_click()
    refute has_element?(view, "#mini-app-context-consent")

    assert_push_event(view, "mini_app_context_response", %{
      launch_id: ^launch_id,
      request_id: "ctx-1",
      status: "ok",
      context: %{
        "version" => "1",
        "sourceUrl" => "https://app.example/shared/chapter-2",
        "launchUrl" => "https://app.example/book/chapter-2",
        "note" => %{
          "id" => _,
          "url" => _,
          "content" => "reader",
          "author" => _,
          "mentions" => []
        }
      }
    })

    render_hook(view, "mini_app_context_request", %{
      "launch_id" => launch_id,
      "request_id" => "ctx-2"
    })

    refute has_element?(view, "#mini-app-context-consent")

    assert_push_event(view, "mini_app_context_response", %{
      launch_id: ^launch_id,
      request_id: "ctx-2",
      status: "ok",
      context: %{}
    })

    view |> element("#mini-app-host-collapse") |> render_click()
    assert has_element?(view, "#mini-app-host[data-state='collapsed']")

    view |> element("#mini-app-host-restore") |> render_click()
    assert has_element?(view, "#mini-app-host[data-state='open']")

    view |> element("#mini-app-host-expand") |> render_click()
    assert has_element?(view, "#mini-app-host[data-expanded='true']")

    view |> element("#mini-app-host-close") |> render_click()
    assert has_element?(view, "#mini-app-host[data-state='closed']")
    refute has_element?(view, "#mini-app-host iframe")

    render_click(view, "mini_app_open", %{"card_id" => Ecto.UUID.generate()})
    assert has_element?(view, "#mini-app-host[data-state='closed']")
    refute has_element?(view, "#mini-app-host iframe")

    assert card.id
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

  defp enable_mini_apps do
    Application.put_env(:egregoros, :mini_apps_enabled, true)

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)
  end
end
