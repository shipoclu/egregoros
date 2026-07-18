defmodule EgregorosWeb.MiniAppHostLiveTest do
  use EgregorosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Egregoros.Activities.Note
  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.DeveloperLaunches
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.MiniApps.NotificationConsents
  alias Egregoros.MiniApps.Permissions
  alias Egregoros.MiniApps.WalletConnections
  alias Egregoros.MiniApps.ResolvedCard
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Timeline
  alias Egregoros.Users

  setup do
    Timeline.reset()

    runtime_policy_keys = [
      Egregoros.Config,
      :mini_apps_enabled,
      :mini_apps_domain_allowlist,
      :mini_apps_domain_denylist
    ]

    previous_runtime_policy =
      Map.new(runtime_policy_keys, &{&1, Application.fetch_env(:egregoros, &1)})

    on_exit(fn ->
      Enum.each(previous_runtime_policy, fn
        {key, {:ok, value}} -> Application.put_env(:egregoros, key, value)
        {key, :error} -> Application.delete_env(:egregoros, key)
      end)
    end)

    enable_mini_apps()
    {:ok, user} = Users.create_local_user("mini-app-host-user")
    %{user: user}
  end

  test "developer launches use synthetic diagnostic context and track ready across retries", %{
    conn: conn,
    user: user
  } do
    {:ok, user} = Users.update_profile(user, %{"developer_mode" => true})
    {:ok, card} = DeveloperLaunches.put(user, resolved_card())
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")

    render_click(view, "mini_app_open", %{
      "card_id" => card.id,
      "resolution_token" => card.resolution_token
    })

    state = :sys.get_state(view.pid).socket.assigns
    launch_id = state.mini_app_host.launch_id

    assert state.mini_app_developer_check == :pending
    assert state.mini_app_developer_card_id == card.id

    assert state.mini_app_host.launch_info == %{
             "version" => "1",
             "launchUrl" => "https://app.example/book/chapter-2",
             "linkedUrl" => "https://app.example/shared/chapter-2",
             "sourceNoteId" => EgregorosWeb.Endpoint.url() <> "/developer/mini-apps"
           }

    render_hook(view, "mini_app_ready", %{"launch_id" => launch_id})
    assert :sys.get_state(view.pid).socket.assigns.mini_app_developer_check == :pass

    render_hook(view, "mini_app_loading", %{"launch_id" => launch_id})
    assert :sys.get_state(view.pid).socket.assigns.mini_app_developer_check == :pending

    render_hook(view, "mini_app_ready_timeout", %{"launch_id" => launch_id})
    assert :sys.get_state(view.pid).socket.assigns.mini_app_developer_check == :fail

    view |> element("#mini-app-frame-retry") |> render_click()
    state = :sys.get_state(view.pid).socket.assigns
    assert state.mini_app_developer_check == :pending
    assert state.mini_app_host.launch_id != launch_id
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
    assert has_element?(view, "[data-role='mini-app-launch-disclosure']", "public post")
    assert has_element?(view, "[data-role='mini-app-launch-disclosure']", "app.example")
    assert has_element?(view, "[data-role='mini-app-launch-disclosure']", "identity")
    refute has_element?(view, "#mini-app-host[data-state='open']")

    assert has_element?(
             view,
             "#mini-app-frame-container[phx-update='ignore'][data-active='false'] #mini-app-frame-shell"
           )

    view |> element("[data-role='open-mini-app']") |> render_click()

    assert has_element?(view, "#mini-app-host[data-state='open']")

    assert has_element?(
             view,
             ~s(#mini-app-host[data-frame-src^="/mini-apps/broker/#{card.id}?launch_id="] > #mini-app-frame-container:first-child[phx-update="ignore"][data-active="true"][data-ready="false"] #mini-app-frame-shell)
           )

    refute has_element?(view, "#mini-app-host iframe")

    refute render(view) =~ ~s(src="https://app.example/book/chapter-2")

    assert has_element?(view, "#mini-app-host[data-app-origin='https://app.example']")
    assert has_element?(view, "#mini-app-host[data-launch-info]")
    assert has_element?(view, "#mini-app-host[phx-hook='MiniAppHost']")
    assert has_element?(view, "#mini-app-frame-container[data-ready='false']")

    launch_id = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id
    launch_info = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_info

    assert launch_info == %{
             "version" => "1",
             "launchUrl" => "https://app.example/book/chapter-2",
             "linkedUrl" => "https://app.example/shared/chapter-2",
             "sourceNoteId" => note.ap_id
           }

    render_hook(view, "mini_app_ready", %{"launch_id" => "wrong"})
    assert has_element?(view, "#mini-app-frame-container[data-ready='false']")

    render_hook(view, "mini_app_ready", %{"launch_id" => launch_id})
    assert has_element?(view, "#mini-app-frame-container[data-ready='true']")
    refute has_element?(view, "#mini-app-host iframe")

    render_hook(view, "mini_app_context_request", %{
      "launch_id" => launch_id,
      "request_id" => "ctx-1"
    })

    assert has_element?(view, "#mini-app-context-consent")
    assert has_element?(view, "#mini-app-context-consent", "app.example")

    assert has_element?(
             view,
             "#mini-app-host > #mini-app-frame-container:first-child[phx-update='ignore']"
           )

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

    assert has_element?(
             view,
             "#mini-app-frame-container[phx-update='ignore'][data-state='collapsed'] #mini-app-frame-shell"
           )

    view |> element("#mini-app-host-restore") |> render_click()
    assert has_element?(view, "#mini-app-host[data-state='open']")
    assert :sys.get_state(view.pid).socket.assigns.mini_app_host.ready?

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

  test "card state broadcasts add and remove a card without reloading the timeline", %{
    conn: conn,
    user: user
  } do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/chapter-2">reader</a>)),
        local: true
      )

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")

    refute has_element?(view, "#post-#{note.id} [data-role='mini-app-card']")

    assert {:ok, _card} = Cards.put(note, resolved_card())
    assert :ok = Timeline.broadcast_mini_app_card_updated(note)
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#post-#{note.id} [data-role='mini-app-card']")

    assert :ok = Cards.delete(note)
    assert :ok = Timeline.broadcast_mini_app_card_updated(note)
    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#post-#{note.id} [data-role='mini-app-card']")
  end

  test "ready timeout offers an exact-origin retry and confirmed external fallback", %{
    conn: conn,
    user: user
  } do
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

    view |> element("#mini-app-host-collapse") |> render_click()
    render_hook(view, "mini_app_ready_timeout", %{"launch_id" => launch_id})
    view |> element("#mini-app-host-restore") |> render_click()
    assert has_element?(view, "#mini-app-frame-container[data-load-error='true']")
    assert has_element?(view, "#mini-app-frame-open-external")

    view |> element("#mini-app-frame-open-external") |> render_click()
    assert has_element?(view, "#mini-app-external-confirmation")

    assert has_element?(
             view,
             "#mini-app-external-confirmation",
             "https://app.example/book/chapter-2"
           )

    view |> element("#mini-app-external-deny") |> render_click()

    view |> element("#mini-app-frame-retry") |> render_click()

    assert has_element?(
             view,
             "#mini-app-frame-container[data-load-error='false'][data-ready='false']"
           )

    new_launch_id = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id
    refute new_launch_id == launch_id

    assert has_element?(
             view,
             ~s(#mini-app-host[data-frame-src*="launch_id=#{new_launch_id}"])
           )
  end

  test "a valid request restores a collapsed live launch instead of replacing its frame", %{
    conn: conn,
    user: user
  } do
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

    view |> element("#mini-app-host-collapse") |> render_click()
    assert has_element?(view, "#mini-app-host[data-state='collapsed']")

    assert has_element?(
             view,
             "#mini-app-frame-container[phx-update='ignore'][data-state='collapsed'] #mini-app-frame-shell"
           )

    render_hook(view, "mini_app_context_request", %{
      "launch_id" => launch_id,
      "request_id" => "context-collapsed"
    })

    assert has_element?(view, "#mini-app-host[data-state='open']")
    assert has_element?(view, "#mini-app-context-consent")
    assert :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id == launch_id
  end

  test "does not grant context after the opened card resolution is replaced", %{
    conn: conn,
    user: user
  } do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/chapter-2">reader</a>)),
        local: true
      )

    assert {:ok, opened_card} = Cards.put(note, resolved_card())
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")
    view |> element("[data-role='open-mini-app']") |> render_click()

    state = :sys.get_state(view.pid).socket.assigns.mini_app_host
    render_hook(view, "mini_app_ready", %{"launch_id" => state.launch_id})

    render_hook(view, "mini_app_context_request", %{
      "launch_id" => state.launch_id,
      "request_id" => "ctx-swap"
    })

    assert has_element?(view, "#mini-app-context-consent", "app.example")

    replacement_manifest = %{
      resolved_card().manifest
      | name: "Replacement",
        origin: "https://replacement.example",
        home_url: "https://replacement.example/"
    }

    replacement = %{
      resolved_card()
      | source_url: "https://replacement.example/shared/chapter-2",
        app_origin: "https://replacement.example",
        app_name: "Replacement",
        launch_url: "https://replacement.example/book/chapter-2",
        image_url: "https://replacement.example/card.png",
        manifest: replacement_manifest
    }

    assert {:ok, replacement_card} = Cards.put(note, replacement)
    assert opened_card.id == replacement_card.id
    refute opened_card.resolution_token == replacement_card.resolution_token

    view |> element("#mini-app-context-approve") |> render_click()

    assert_push_event(view, "mini_app_context_response", %{
      launch_id: _,
      request_id: "ctx-swap",
      status: "unavailable",
      context: nil
    })

    refute Egregoros.MiniApps.ContextConsents.approved?(
             user.id,
             "https://replacement.example"
           )
  end

  test "validates auth requests against the card origin and presents a host-controlled prompt", %{
    conn: conn,
    user: user
  } do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/write">writer</a>)),
        local: true
      )

    resolved = resolved_card(oauth?: true)
    assert {:ok, _registration} = OAuthRegistrations.register(resolved.manifest)
    assert {:ok, _card} = Cards.put(note, resolved)

    application =
      Egregoros.OAuth.get_application_by_client_id(client_id_for("https://app.example"))

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")
    view |> element("[data-role='open-mini-app']") |> render_click()

    state = :sys.get_state(view.pid).socket.assigns.mini_app_host
    render_hook(view, "mini_app_ready", %{"launch_id" => state.launch_id})

    params = auth_params(state.launch_id, application.client_id)
    render_hook(view, "mini_app_auth_request", params)

    assert has_element?(view, "#mini-app-auth-consent")

    assert has_element?(
             view,
             "#mini-app-auth-open[data-role='mini-app-auth-open'][data-request-id='auth-1'][data-auth-state='#{String.duplicate("s", 43)}']"
           )

    href =
      view
      |> element("#mini-app-auth-open")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-auth-url")
      |> List.first()

    query = href |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["client_id"] == application.client_id
    assert query["redirect_uri"] == "https://app.example/oauth/callback"
    assert query["scope"] == "identify write"
    assert query["authorization_lifetime_seconds"] == "86400"
    refute Map.has_key?(query, "handoff_challenge")

    view |> element("#mini-app-auth-cancel") |> render_click()
    refute has_element?(view, "#mini-app-auth-consent")

    assert_push_event(view, "mini_app_auth_response", %{
      launch_id: _,
      request_id: "auth-1",
      status: "cancelled"
    })

    render_hook(view, "mini_app_auth_request", %{
      params
      | "client_id" => String.duplicate("x", 32)
    })

    refute has_element?(view, "#mini-app-auth-consent")

    assert_push_event(view, "mini_app_auth_response", %{
      launch_id: _,
      request_id: "auth-1",
      status: "invalid_request"
    })
  end

  test "compose needs no OAuth and publishes only from the host form", %{
    conn: conn,
    user: user
  } do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/write">writer</a>)),
        local: true
      )

    resolved = resolved_card(compose?: true)
    assert {:ok, _card} = Cards.put(note, resolved)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")
    view |> element("[data-role='open-mini-app']") |> render_click()

    launch_id = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id
    render_hook(view, "mini_app_ready", %{"launch_id" => launch_id})

    object_count_before_compose = Egregoros.Repo.aggregate(Egregoros.Object, :count)

    compose_params = %{
      "launch_id" => launch_id,
      "call_id" => "compose-call-1",
      "draft" => %{
        "text" => "Initial result",
        "spoilerText" => "Result",
        "language" => "en",
        "visibility" => "unlisted",
        "inReplyTo" => note.ap_id,
        "links" => ["https://app.example/results/1"]
      }
    }

    render_hook(view, "mini_app_compose_request", compose_params)
    assert has_element?(view, "#mini-app-compose-sheet")
    assert has_element?(view, "#mini-app-compose-form")
    assert has_element?(view, "#mini-app-compose-form textarea", "Initial result")
    assert Egregoros.Repo.aggregate(Egregoros.Object, :count) == object_count_before_compose

    assert_push_event(view, "mini_app_compose_response", %{
      launch_id: ^launch_id,
      call_id: "compose-call-1",
      request_id: request_id,
      status: "accepted"
    })

    view
    |> form("#mini-app-compose-form", %{
      "mini_app_post" => %{
        "content" => "Edited and explicitly submitted",
        "spoiler_text" => "",
        "language" => "en",
        "visibility" => "unlisted"
      }
    })
    |> render_submit()

    refute has_element?(view, "#mini-app-compose-sheet")

    assert_push_event(view, "mini_app_compose_published", %{
      launch_id: ^launch_id,
      request_id: ^request_id,
      id: published_id,
      scope: "unlisted"
    })

    assert %{data: %{"source" => %{"content" => "Edited and explicitly submitted"}}} =
             Objects.get_by_ap_id(published_id)
  end

  test "compose still requires a signed-in host session", %{conn: conn, user: user} do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/anonymous">writer</a>)),
        local: true
      )

    assert {:ok, _card} = Cards.put(note, resolved_card(compose?: true))

    {:ok, view, _html} = live(conn, "/?timeline=public")
    view |> element("[data-role='open-mini-app']") |> render_click()

    launch_id = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id
    render_hook(view, "mini_app_ready", %{"launch_id" => launch_id})

    render_hook(view, "mini_app_compose_request", %{
      "launch_id" => launch_id,
      "call_id" => "compose-anonymous",
      "draft" => %{"text" => "Cannot submit without a host user"}
    })

    refute has_element?(view, "#mini-app-compose-sheet")

    assert_push_event(view, "mini_app_compose_response", %{
      launch_id: ^launch_id,
      call_id: "compose-anonymous",
      status: "unavailable"
    })
  end

  test "compose remains available when the app also has an active OAuth grant", %{
    conn: conn,
    user: user
  } do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/existing-grant">writer</a>)),
        local: true
      )

    resolved = resolved_card(oauth?: true)
    assert {:ok, registration} = OAuthRegistrations.register(resolved.manifest)
    assert {:ok, _card} = Cards.put(note, resolved)

    application =
      Egregoros.Repo.get!(Egregoros.OAuth.Application, registration.oauth_application_id)

    complete_oauth_grant(application, user)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")
    view |> element("[data-role='open-mini-app']") |> render_click()

    launch_id = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id
    render_hook(view, "mini_app_ready", %{"launch_id" => launch_id})

    render_hook(view, "mini_app_compose_request", %{
      "launch_id" => launch_id,
      "call_id" => "compose-existing-grant",
      "draft" => %{"text" => "Restored app session", "visibility" => "public"}
    })

    assert has_element?(view, "#mini-app-compose-sheet")

    assert_push_event(view, "mini_app_compose_response", %{
      launch_id: ^launch_id,
      call_id: "compose-existing-grant",
      request_id: _,
      status: "accepted"
    })
  end

  test "browser-code completion accepts only its exact pending PKCE code", %{
    conn: conn,
    user: user
  } do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/browser-auth">browser auth</a>)),
        local: true
      )

    resolved = resolved_card(oauth?: true)
    assert {:ok, _registration} = OAuthRegistrations.register(resolved.manifest)
    assert {:ok, _card} = Cards.put(note, resolved)

    application =
      Egregoros.OAuth.get_application_by_client_id(client_id_for("https://app.example"))

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")
    view |> element("[data-role='open-mini-app']") |> render_click()

    launch_id = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id
    render_hook(view, "mini_app_ready", %{"launch_id" => launch_id})

    browser_auth =
      launch_id
      |> auth_params(application.client_id)
      |> Map.put("completion_mode", "browser_code")
      |> Map.delete("handoff_challenge")

    render_hook(view, "mini_app_auth_request", browser_auth)

    assert has_element?(
             view,
             "#mini-app-auth-open[data-auth-completion-mode='browser_code']"
           )

    assert {:ok, authorization_code} =
             Egregoros.OAuth.create_authorization_code(
               application,
               user,
               "https://app.example/oauth/callback",
               "identify write",
               code_challenge: String.duplicate("c", 43),
               code_challenge_method: "S256",
               grant_ttl_seconds: 86_400
             )

    render_hook(view, "mini_app_auth_complete", %{
      "launch_id" => launch_id,
      "request_id" => "auth-1",
      "status" => "success",
      "authorization_code" => String.duplicate("x", 43)
    })

    refute :sys.get_state(view.pid).socket.assigns.mini_app_host.oauth_authenticated?

    render_hook(
      view,
      "mini_app_auth_request",
      %{browser_auth | "request_id" => "auth-2"}
    )

    render_hook(view, "mini_app_auth_complete", %{
      "launch_id" => launch_id,
      "request_id" => "auth-2",
      "status" => "success",
      "authorization_code" => authorization_code.code
    })

    assert :sys.get_state(view.pid).socket.assigns.mini_app_host.oauth_authenticated?
  end

  test "compose remains available after an unrelated OAuth grant is revoked", %{
    conn: conn,
    user: user
  } do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/write">writer</a>)),
        local: true
      )

    resolved = resolved_card(oauth?: true)
    assert {:ok, registration} = OAuthRegistrations.register(resolved.manifest)
    assert {:ok, _card} = Cards.put(note, resolved)

    application =
      Egregoros.Repo.get!(Egregoros.OAuth.Application, registration.oauth_application_id)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")
    view |> element("[data-role='open-mini-app']") |> render_click()

    launch_id = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id
    render_hook(view, "mini_app_ready", %{"launch_id" => launch_id})

    render_hook(view, "mini_app_auth_request", auth_params(launch_id, application.client_id))
    first_token = complete_oauth_grant(application, user)

    render_hook(view, "mini_app_auth_complete", %{
      "launch_id" => launch_id,
      "request_id" => "auth-1",
      "status" => "success"
    })

    revoke_token_directly!(first_token)

    draft = %{
      "text" => "Compose is authorized by the host confirmation",
      "visibility" => "public",
      "links" => []
    }

    render_hook(view, "mini_app_compose_request", %{
      "launch_id" => launch_id,
      "call_id" => "compose-with-revoked-oauth",
      "draft" => draft
    })

    assert has_element?(view, "#mini-app-compose-sheet")

    assert_push_event(view, "mini_app_compose_response", %{
      launch_id: ^launch_id,
      call_id: "compose-with-revoked-oauth",
      request_id: request_id,
      status: "accepted"
    })

    view
    |> form("#mini-app-compose-form", %{
      "mini_app_post" => %{
        "content" => "Published through explicit host confirmation",
        "spoiler_text" => "",
        "language" => "en",
        "visibility" => "public"
      }
    })
    |> render_submit()

    refute has_element?(view, "#mini-app-compose-error")

    assert_push_event(view, "mini_app_compose_published", %{
      launch_id: ^launch_id,
      request_id: ^request_id,
      id: published_id,
      scope: "public"
    })

    assert %{data: %{"source" => %{"content" => "Published through explicit host confirmation"}}} =
             Objects.get_by_ap_id(published_id)
  end

  test "compose rechecks policy after waiting on the serialization boundary", %{
    conn: conn,
    user: user
  } do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/write">writer</a>)),
        local: true
      )

    resolved = resolved_card(oauth?: true)
    assert {:ok, registration} = OAuthRegistrations.register(resolved.manifest)
    assert {:ok, _card} = Cards.put(note, resolved)

    application =
      Egregoros.Repo.get!(Egregoros.OAuth.Application, registration.oauth_application_id)

    use_runtime_mini_apps_policy([])
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")
    view |> element("[data-role='open-mini-app']") |> render_click()

    launch_id = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id
    render_hook(view, "mini_app_ready", %{"launch_id" => launch_id})
    render_hook(view, "mini_app_auth_request", auth_params(launch_id, application.client_id))
    insert_active_oauth_grant!(application, user)

    render_hook(view, "mini_app_auth_complete", %{
      "launch_id" => launch_id,
      "request_id" => "auth-1",
      "status" => "success"
    })

    render_hook(view, "mini_app_compose_request", %{
      "launch_id" => launch_id,
      "call_id" => "compose-revoke-race",
      "draft" => %{
        "text" => "Wait for the shared grant boundary",
        "visibility" => "public",
        "links" => []
      }
    })

    assert has_element?(view, "#mini-app-compose-sheet")
    object_count = Egregoros.Repo.aggregate(Egregoros.Object, :count)
    [[compose_backend_pid]] = Egregoros.Repo.query!("SELECT pg_backend_pid()").rows
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Egregoros.Repo)

        try do
          Egregoros.Repo.transaction(fn ->
            Egregoros.MiniApps.GrantLock.acquire(user.id, "https://app.example")
            send(parent, {:compose_grant_lock_held, self()})

            receive do
              :release -> :released
            end
          end)
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Egregoros.Repo)
        end
      end)

    assert_receive {:compose_grant_lock_held, holder_pid}, 1_000

    submitter =
      Task.Supervisor.async_nolink(supervisor, fn ->
        view
        |> form("#mini-app-compose-form", %{
          "mini_app_post" => %{
            "content" => "This must not outlive the app policy",
            "spoiler_text" => "",
            "language" => "en",
            "visibility" => "public"
          }
        })
        |> render_submit()
      end)

    observer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Egregoros.Repo)

        try do
          wait_for_blocked_advisory_lock(
            compose_backend_pid,
            System.monotonic_time(:millisecond) + 2_000
          )
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Egregoros.Repo)
        end
      end)

    assert :ok = Task.await(observer, 3_000)
    use_runtime_mini_apps_policy(["app.example"])
    send(holder_pid, :release)
    assert {:ok, :released} = Task.await(holder, 3_000)
    _html = Task.await(submitter, 3_000)

    assert has_element?(view, "#mini-app-compose-error")
    refute_push_event(view, "mini_app_compose_published", %{launch_id: ^launch_id})
    assert Egregoros.Repo.aggregate(Egregoros.Object, :count) == object_count
  end

  test "notification permission requires OAuth and uses a host-owned decision dialog", %{
    conn: conn,
    user: user
  } do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/alerts">alerts</a>)),
        local: true
      )

    resolved = resolved_card(oauth?: true, notifications?: true)
    assert {:ok, registration} = OAuthRegistrations.register(resolved.manifest)
    assert {:ok, _card} = Cards.put(note, resolved)
    activate_mini_app_actor!("https://app.example")

    application =
      Egregoros.Repo.get!(Egregoros.OAuth.Application, registration.oauth_application_id)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")
    view |> element("[data-role='open-mini-app']") |> render_click()

    assert has_element?(
             view,
             "#mini-app-host[data-notifications-enabled='true'][data-notifications-actor-url='https://app.example/ap/actor']"
           )

    launch_id = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id
    render_hook(view, "mini_app_ready", %{"launch_id" => launch_id})

    render_hook(view, "mini_app_notification_permission_request", %{
      "launch_id" => launch_id,
      "request_id" => "notification-before-auth",
      "action" => "get"
    })

    assert_push_event(view, "mini_app_notification_permission_response", %{
      launch_id: ^launch_id,
      request_id: "notification-before-auth",
      status: "auth_required"
    })

    complete_oauth_grant(application, user)

    render_hook(view, "mini_app_notification_permission_request", %{
      "launch_id" => launch_id,
      "request_id" => "notification-get",
      "action" => "get"
    })

    assert_push_event(view, "mini_app_notification_permission_response", %{
      launch_id: ^launch_id,
      request_id: "notification-get",
      status: "ok",
      state: "prompt",
      actor_url: "https://app.example/ap/actor"
    })

    render_hook(view, "mini_app_notification_permission_request", %{
      "launch_id" => launch_id,
      "request_id" => "notification-prompt-deny",
      "action" => "request"
    })

    assert has_element?(view, "#mini-app-notification-consent")
    assert has_element?(view, "#mini-app-notification-consent", "https://app.example/ap/actor")
    view |> element("#mini-app-notification-deny") |> render_click()
    assert NotificationConsents.state(user.id, "https://app.example") == :denied

    assert_push_event(view, "mini_app_notification_permission_response", %{
      launch_id: ^launch_id,
      request_id: "notification-prompt-deny",
      status: "ok",
      state: "denied",
      actor_url: "https://app.example/ap/actor"
    })

    render_hook(view, "mini_app_notification_permission_request", %{
      "launch_id" => launch_id,
      "request_id" => "notification-prompt-grant",
      "action" => "request"
    })

    view |> element("#mini-app-notification-approve") |> render_click()
    assert NotificationConsents.granted?(user.id, "https://app.example")

    assert_push_event(view, "mini_app_notification_permission_response", %{
      launch_id: ^launch_id,
      request_id: "notification-prompt-grant",
      status: "ok",
      state: "granted",
      actor_url: "https://app.example/ap/actor"
    })

    assert :ok = NotificationConsents.revoke(user.id, "https://app.example")
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#mini-app-host[data-state='closed']")
  end

  test "external navigation requires host confirmation and close is launch-bound", %{
    conn: conn,
    user: user
  } do
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

    render_hook(view, "mini_app_external_request", %{
      "launch_id" => launch_id,
      "request_id" => "external-invalid",
      "url" => "javascript:alert(1)"
    })

    refute has_element?(view, "#mini-app-external-confirmation")

    assert_push_event(view, "mini_app_external_response", %{
      launch_id: ^launch_id,
      request_id: "external-invalid",
      status: "invalid_request"
    })

    render_hook(view, "mini_app_external_request", %{
      "launch_id" => launch_id,
      "request_id" => "external-1",
      "url" => "https://docs.example/chapter/1"
    })

    assert has_element?(view, "#mini-app-external-confirmation")

    assert has_element?(
             view,
             "#mini-app-external-open[data-role='mini-app-external-open'][data-external-url='https://docs.example/chapter/1']"
           )

    view |> element("#mini-app-external-open") |> render_click()
    refute has_element?(view, "#mini-app-external-confirmation")

    assert_push_event(view, "mini_app_external_response", %{
      launch_id: ^launch_id,
      request_id: "external-1",
      status: "approved"
    })

    render_hook(view, "mini_app_external_request", %{
      "launch_id" => launch_id,
      "request_id" => "external-2",
      "url" => "https://docs.example/chapter/2"
    })

    view |> element("#mini-app-external-deny") |> render_click()

    assert_push_event(view, "mini_app_external_response", %{
      launch_id: ^launch_id,
      request_id: "external-2",
      status: "denied"
    })

    render_hook(view, "mini_app_close_request", %{
      "launch_id" => "wrong",
      "request_id" => "close-1"
    })

    assert has_element?(view, "#mini-app-host[data-state='open']")

    render_hook(view, "mini_app_close_request", %{
      "launch_id" => launch_id,
      "request_id" => "close-1"
    })

    assert has_element?(view, "#mini-app-host[data-state='closed']")
  end

  test "wallet accounts remain private until the host confirms connection", %{
    conn: conn,
    user: user
  } do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/wallet">wallet</a>)),
        local: true
      )

    assert {:ok, _card} = Cards.put(note, resolved_card(wallet?: true))
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")
    view |> element("[data-role='open-mini-app']") |> render_click()

    assert has_element?(
             view,
             "#mini-app-host[data-wallet-enabled='true'][data-wallet-required='false']"
           )

    launch_id = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id
    render_hook(view, "mini_app_ready", %{"launch_id" => launch_id})

    render_hook(view, "mini_app_wallet_request", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-chain",
      "method" => "eth_chainId",
      "params" => []
    })

    assert_push_event(view, "mini_app_wallet_execute", %{
      launch_id: ^launch_id,
      request_id: "wallet-chain",
      method: "eth_chainId",
      params: [],
      execution_token: chain_token
    })

    assert byte_size(chain_token) == 43

    render_hook(view, "mini_app_wallet_execution_result", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-chain",
      "method" => "eth_chainId",
      "execution_token" => chain_token,
      "status" => "ok",
      "result" => "0x2105"
    })

    assert_push_event(view, "mini_app_wallet_response", %{
      launch_id: ^launch_id,
      request_id: "wallet-chain",
      result: "0x2105"
    })

    render_hook(view, "mini_app_wallet_request", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-chain-error",
      "method" => "eth_chainId",
      "params" => []
    })

    assert_push_event(view, "mini_app_wallet_execute", %{
      launch_id: ^launch_id,
      request_id: "wallet-chain-error",
      method: "eth_chainId",
      params: [],
      execution_token: chain_error_token
    })

    render_hook(view, "mini_app_wallet_execution_result", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-chain-error",
      "method" => "eth_chainId",
      "execution_token" => chain_error_token,
      "status" => "error",
      "code" => 4900
    })

    assert_push_event(view, "mini_app_wallet_response", %{
      launch_id: ^launch_id,
      request_id: "wallet-chain-error",
      error: %{code: 4900, message: "Wallet request failed"}
    })

    render_hook(view, "mini_app_wallet_request", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-chain-invalid",
      "method" => "eth_chainId",
      "params" => []
    })

    assert_push_event(view, "mini_app_wallet_execute", %{
      launch_id: ^launch_id,
      request_id: "wallet-chain-invalid",
      method: "eth_chainId",
      params: [],
      execution_token: chain_invalid_token
    })

    render_hook(view, "mini_app_wallet_execution_result", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-chain-invalid",
      "method" => "eth_chainId",
      "execution_token" => chain_invalid_token,
      "status" => "ok",
      "result" => "not-a-chain"
    })

    assert_push_event(view, "mini_app_wallet_response", %{
      launch_id: ^launch_id,
      request_id: "wallet-chain-invalid",
      error: %{code: -32603, message: "Invalid wallet response"}
    })

    render_hook(view, "mini_app_wallet_request", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-accounts",
      "method" => "eth_accounts",
      "params" => []
    })

    assert_push_event(view, "mini_app_wallet_response", %{
      launch_id: ^launch_id,
      request_id: "wallet-accounts",
      result: []
    })

    render_hook(view, "mini_app_wallet_request", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-connect",
      "method" => "eth_requestAccounts",
      "params" => []
    })

    assert has_element?(view, "#mini-app-wallet-connection")
    view |> element("#mini-app-wallet-deny") |> render_click()

    assert_push_event(view, "mini_app_wallet_response", %{
      launch_id: ^launch_id,
      request_id: "wallet-connect",
      error: %{code: 4001, message: "User rejected wallet connection"}
    })

    refute WalletConnections.connected?(user.id, "https://app.example")

    render_hook(view, "mini_app_wallet_request", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-connect-2",
      "method" => "eth_requestAccounts",
      "params" => []
    })

    view |> element("#mini-app-wallet-connect") |> render_click()

    assert_push_event(view, "mini_app_wallet_execute", %{
      launch_id: ^launch_id,
      request_id: "wallet-connect-2",
      method: "eth_requestAccounts",
      params: [],
      execution_token: connect_token
    })

    accounts = [
      "0x1111111111111111111111111111111111111111",
      "0x2222222222222222222222222222222222222222"
    ]

    render_hook(view, "mini_app_wallet_execution_result", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-connect-2",
      "method" => "eth_requestAccounts",
      "execution_token" => connect_token,
      "status" => "ok",
      "result" => accounts
    })

    assert WalletConnections.accounts(user.id, "https://app.example") == accounts

    assert_push_event(view, "mini_app_wallet_response", %{
      launch_id: ^launch_id,
      request_id: "wallet-connect-2",
      result: ^accounts
    })

    render_hook(view, "mini_app_wallet_request", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-accounts-2",
      "method" => "eth_accounts",
      "params" => []
    })

    assert_push_event(view, "mini_app_wallet_execute", %{
      launch_id: ^launch_id,
      request_id: "wallet-accounts-2",
      method: "eth_accounts",
      params: [],
      execution_token: accounts_token
    })

    render_hook(view, "mini_app_wallet_execution_result", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-accounts-2",
      "method" => "eth_accounts",
      "execution_token" => accounts_token,
      "status" => "ok",
      "result" => [List.first(accounts), "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
    })

    assert_push_event(view, "mini_app_wallet_response", %{
      launch_id: ^launch_id,
      request_id: "wallet-accounts-2",
      result: ["0x1111111111111111111111111111111111111111"]
    })
  end

  test "required wallet incompatibility blocks the framed experience", %{conn: conn, user: user} do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/wallet">wallet</a>)),
        local: true
      )

    assert {:ok, _card} = Cards.put(note, resolved_card(wallet_required?: true))
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")
    view |> element("[data-role='open-mini-app']") |> render_click()
    launch_id = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id

    render_hook(view, "mini_app_wallet_availability", %{
      "launch_id" => launch_id,
      "compatible" => false
    })

    assert has_element?(view, "#mini-app-wallet-incompatible")
  end

  test "permission revocation immediately tears down the matching active app", %{
    conn: conn,
    user: user
  } do
    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/chapter">reader</a>)),
        local: true
      )

    assert {:ok, _card} = Cards.put(note, resolved_card())
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")
    view |> element("[data-role='open-mini-app']") |> render_click()
    assert has_element?(view, "#mini-app-host[data-state='open']")

    :ok = Permissions.notify_revoked(user.id, "https://app.example", :context)
    _ = render(view)

    assert has_element?(view, "#mini-app-host[data-state='closed']")
  end

  test "privileged wallet requests are reviewed exactly and rechecked before execution", %{
    conn: conn,
    user: user
  } do
    account = "0x1111111111111111111111111111111111111111"
    params = ["0x68656c6c6f", account]

    {:ok, note} =
      Pipeline.ingest(
        Note.build(user, ~s(<a href="https://app.example/shared/wallet">wallet</a>)),
        local: true
      )

    assert {:ok, _card} = Cards.put(note, resolved_card(wallet?: true))

    assert {:ok, _connection} =
             WalletConnections.connect(user.id, "https://app.example", [account])

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/?timeline=public")
    view |> element("[data-role='open-mini-app']") |> render_click()
    launch_id = :sys.get_state(view.pid).socket.assigns.mini_app_host.launch_id
    render_hook(view, "mini_app_ready", %{"launch_id" => launch_id})

    render_hook(view, "mini_app_wallet_request", %{
      "launch_id" => launch_id,
      "request_id" => "sign-1",
      "method" => "personal_sign",
      "params" => params
    })

    assert_push_event(view, "mini_app_wallet_preflight", %{
      launch_id: ^launch_id,
      request_id: "sign-1"
    })

    render_hook(view, "mini_app_wallet_preflight_result", %{
      "launch_id" => launch_id,
      "request_id" => "sign-1",
      "status" => "ok",
      "chain_id" => "0x2105",
      "accounts" => [account]
    })

    assert has_element?(view, "#mini-app-wallet-approval[data-method='personal_sign']")
    assert has_element?(view, "#mini-app-wallet-review-message", "0x68656c6c6f")

    assert has_element?(
             view,
             "#mini-app-wallet-review-exact",
             ~s({"method":"personal_sign","params":["0x68656c6c6f","#{account}"]})
           )

    view |> element("#mini-app-wallet-approve") |> render_click()

    assert_push_event(view, "mini_app_wallet_execute", %{
      launch_id: ^launch_id,
      request_id: "sign-1",
      method: "personal_sign",
      params: ^params,
      expected_chain_id: "0x2105",
      expected_accounts: [^account],
      execution_token: execution_token
    })

    assert byte_size(execution_token) == 43

    signature = "0x" <> String.duplicate("ab", 65)

    render_hook(view, "mini_app_wallet_execution_result", %{
      "launch_id" => launch_id,
      "request_id" => "sign-1",
      "method" => "eth_sendTransaction",
      "execution_token" => execution_token,
      "status" => "ok",
      "result" => signature
    })

    refute_push_event(view, "mini_app_wallet_response", %{
      launch_id: ^launch_id,
      request_id: "sign-1"
    })

    render_hook(view, "mini_app_wallet_execution_result", %{
      "launch_id" => launch_id,
      "request_id" => "sign-1",
      "method" => "personal_sign",
      "execution_token" => String.duplicate("x", 43),
      "status" => "ok",
      "result" => signature
    })

    refute_push_event(view, "mini_app_wallet_response", %{
      launch_id: ^launch_id,
      request_id: "sign-1"
    })

    render_hook(view, "mini_app_wallet_execution_result", %{
      "launch_id" => launch_id,
      "request_id" => "sign-1",
      "method" => "personal_sign",
      "execution_token" => execution_token,
      "status" => "ok",
      "result" => signature
    })

    assert_push_event(view, "mini_app_wallet_response", %{
      launch_id: ^launch_id,
      request_id: "sign-1",
      result: ^signature
    })

    render_hook(view, "mini_app_wallet_preflight_result", %{
      "launch_id" => launch_id,
      "request_id" => "malformed"
    })

    assert has_element?(view, "#mini-app-host[data-state='open']")
  end

  defp resolved_card(options \\ []) do
    oauth? = Keyword.get(options, :oauth?, false)
    compose? = Keyword.get(options, :compose?, oauth?)
    notifications? = Keyword.get(options, :notifications?, false)
    wallet? = Keyword.get(options, :wallet?, false)
    wallet_required? = Keyword.get(options, :wallet_required?, false)

    manifest = %Manifest{
      version: "1",
      name: "Reader",
      origin: "https://app.example",
      home_url: "https://app.example/",
      oauth:
        if(oauth?,
          do: %{
            redirect_uris: ["https://app.example/oauth/callback"],
            scopes: ["identify", "write"],
            scope_authorization_max_age_seconds: %{
              "identify" => 31_536_000,
              "write" => 86_400
            }
          },
          else: nil
        ),
      wallet:
        if(wallet? or wallet_required?,
          do: %{
            evm: %{
              enabled: true,
              required: wallet_required?,
              required_chains: ["eip155:8453"]
            }
          },
          else: nil
        ),
      activity_pub:
        if(notifications?,
          do: %{
            actor_url: "https://app.example/ap/actor",
            public_notes: true,
            transactional_mentions: true
          },
          else: nil
        ),
      capabilities: if(compose?, do: ["compose_note"], else: []),
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

  defp client_id_for(origin) do
    registration = OAuthRegistrations.get_by_origin(origin)
    Egregoros.Repo.get!(Egregoros.OAuth.Application, registration.oauth_application_id).client_id
  end

  defp auth_params(launch_id, client_id, request_id \\ "auth-1") do
    %{
      "launch_id" => launch_id,
      "request_id" => request_id,
      "client_id" => client_id,
      "redirect_uri" => "https://app.example/oauth/callback",
      "scopes" => ["identify", "write"],
      "state" => String.duplicate("s", 43),
      "code_challenge" => String.duplicate("c", 43),
      "code_challenge_method" => "S256",
      "handoff_challenge" => String.duplicate("h", 43),
      "authorization_lifetime_seconds" => 86_400
    }
  end

  defp complete_oauth_grant(application, user) do
    verifier = String.duplicate("v", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert {:ok, code} =
             Egregoros.OAuth.create_authorization_code(
               application,
               user,
               "https://app.example/oauth/callback",
               "identify write",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:ok, token} =
             Egregoros.OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => code.code,
               "client_id" => application.client_id,
               "redirect_uri" => "https://app.example/oauth/callback",
               "code_verifier" => verifier
             })

    token
  end

  defp revoke_token_directly!(token) do
    token
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
    |> Egregoros.Repo.update!()
  end

  defp insert_active_oauth_grant!(application, user) do
    raw_token = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
    raw_refresh_token = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

    %Egregoros.OAuth.Token{}
    |> Egregoros.OAuth.Token.changeset(%{
      token_digest: token_digest(raw_token),
      refresh_token_digest: token_digest(raw_refresh_token),
      family_id: Ecto.UUID.generate(),
      scopes: "identify write",
      user_id: user.id,
      application_id: application.id,
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
      refresh_expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
    })
    |> Egregoros.Repo.insert!()
  end

  defp token_digest(token) do
    token
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp wait_for_blocked_advisory_lock(backend_pid, deadline) do
    [[waiting?]] =
      Egregoros.Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_locks
          WHERE pid = $1 AND locktype = 'advisory' AND granted = false
        )
        """,
        [backend_pid]
      ).rows

    cond do
      waiting? ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        wait_for_blocked_advisory_lock(backend_pid, deadline)

      true ->
        {:error, :lock_not_observed}
    end
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

  defp use_runtime_mini_apps_policy(denylist) do
    Application.put_env(:egregoros, Egregoros.Config, Egregoros.Config.Stub)
    Application.put_env(:egregoros, :mini_apps_enabled, true)
    Application.put_env(:egregoros, :mini_apps_domain_allowlist, [])
    Application.put_env(:egregoros, :mini_apps_domain_denylist, denylist)
  end
end
