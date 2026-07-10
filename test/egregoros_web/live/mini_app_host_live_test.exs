defmodule EgregorosWeb.MiniAppHostLiveTest do
  use EgregorosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Egregoros.Activities.Note
  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.MiniApps.ResolvedCard
  alias Egregoros.Objects
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
             "#mini-app-auth-open[data-role='mini-app-auth-open'][data-request-id='auth-1']"
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
    assert query["scope"] == "read write"
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

  test "compose requires completed OAuth and publishes only from the host form", %{
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
    refute has_element?(view, "#mini-app-compose-sheet")

    assert_push_event(view, "mini_app_compose_response", %{
      launch_id: ^launch_id,
      call_id: "compose-call-1",
      status: "auth_required"
    })

    auth = auth_params(launch_id, application.client_id)
    render_hook(view, "mini_app_auth_request", auth)

    render_hook(view, "mini_app_auth_complete", %{
      "launch_id" => launch_id,
      "request_id" => "auth-1",
      "status" => "success"
    })

    refute :sys.get_state(view.pid).socket.assigns.mini_app_host.oauth_authenticated?

    render_hook(
      view,
      "mini_app_auth_request",
      auth_params(launch_id, application.client_id, "auth-2")
    )

    complete_oauth_grant(application, user)

    render_hook(view, "mini_app_auth_complete", %{
      "launch_id" => launch_id,
      "request_id" => "auth-2",
      "status" => "success"
    })

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

  defp resolved_card(options \\ []) do
    oauth? = Keyword.get(options, :oauth?, false)

    manifest = %Manifest{
      version: "1",
      name: "Reader",
      origin: "https://app.example",
      home_url: "https://app.example/",
      oauth:
        if(oauth?,
          do: %{
            redirect_uris: ["https://app.example/oauth/callback"],
            scopes: ["read", "write"]
          },
          else: nil
        ),
      capabilities: if(oauth?, do: ["compose_note"], else: []),
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
      "scopes" => ["read", "write"],
      "state" => String.duplicate("s", 43),
      "code_challenge" => String.duplicate("c", 43),
      "code_challenge_method" => "S256",
      "handoff_challenge" => String.duplicate("h", 43)
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
               "read write",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:ok, _token} =
             Egregoros.OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => code.code,
               "client_id" => application.client_id,
               "client_secret" => application.client_secret,
               "redirect_uri" => "https://app.example/oauth/callback",
               "code_verifier" => verifier
             })
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
