defmodule EgregorosWeb.MiniAppHostLiveTest do
  use EgregorosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Egregoros.Activities.Note
  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.MiniApps.WalletConnections
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
      params: []
    })

    render_hook(view, "mini_app_wallet_execution_result", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-chain",
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

    render_hook(view, "mini_app_wallet_execution_result", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-chain-error",
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

    render_hook(view, "mini_app_wallet_execution_result", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-chain-invalid",
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
      params: []
    })

    accounts = [
      "0x1111111111111111111111111111111111111111",
      "0x2222222222222222222222222222222222222222"
    ]

    render_hook(view, "mini_app_wallet_execution_result", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-connect-2",
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
      params: []
    })

    render_hook(view, "mini_app_wallet_execution_result", %{
      "launch_id" => launch_id,
      "request_id" => "wallet-accounts-2",
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

    view |> element("#mini-app-wallet-approve") |> render_click()

    assert_push_event(view, "mini_app_wallet_execute", %{
      launch_id: ^launch_id,
      request_id: "sign-1",
      method: "personal_sign",
      params: ^params,
      expected_chain_id: "0x2105",
      expected_accounts: [^account]
    })

    signature = "0x" <> String.duplicate("ab", 65)

    render_hook(view, "mini_app_wallet_execution_result", %{
      "launch_id" => launch_id,
      "request_id" => "sign-1",
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
            scopes: ["read", "write"]
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
