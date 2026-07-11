defmodule EgregorosWeb.PrivacyLiveTest do
  use EgregorosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Egregoros.Relationships
  alias Egregoros.MiniApps.ContextConsents
  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.NotificationConsents
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.MiniApps.WalletConnections
  alias Egregoros.OAuth
  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.Repo
  alias Egregoros.Users

  setup do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    {:ok, carol} = Users.create_local_user("carol")

    {:ok, mute} =
      Relationships.upsert_relationship(%{
        type: "Mute",
        actor: alice.ap_id,
        object: bob.ap_id,
        activity_ap_id: nil
      })

    {:ok, block} =
      Relationships.upsert_relationship(%{
        type: "Block",
        actor: alice.ap_id,
        object: carol.ap_id,
        activity_ap_id: nil
      })

    %{alice: alice, bob: bob, carol: carol, mute: mute, block: block}
  end

  test "lists and disconnects mini-app wallet connections independently", %{
    conn: conn,
    alice: alice
  } do
    assert {:ok, _declaration, :created} = Declarations.ensure(wallet_manifest())

    assert {:ok, connection} =
             WalletConnections.connect(alice.id, "https://wallet.example", [
               "0x1111111111111111111111111111111111111111"
             ])

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/settings/privacy")

    assert has_element?(view, "#wallet-connection-#{connection.id}")

    assert has_element?(
             view,
             "#wallet-connection-#{connection.id} [data-role='wallet-account']",
             "0x1111111111111111111111111111111111111111"
           )

    view
    |> element(
      "button[data-role='privacy-disconnect-wallet'][phx-value-origin='https://wallet.example']"
    )
    |> render_click()

    assert WalletConnections.list_for_user(alice.id) == []
    refute has_element?(view, "#wallet-connection-#{connection.id}")
  end

  test "lists and revokes mini-app context disclosure", %{conn: conn, alice: alice} do
    assert {:ok, consent} = ContextConsents.grant(alice.id, "https://reader.example")
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/settings/privacy")

    assert has_element?(view, "#context-consent-#{consent.id}")

    view
    |> element(
      "button[data-role='privacy-revoke-context'][phx-value-origin='https://reader.example']"
    )
    |> render_click()

    refute ContextConsents.approved?(alice.id, "https://reader.example")
    refute has_element?(view, "#context-consent-#{consent.id}")
  end

  test "lists and revokes mini-app OAuth access", %{conn: conn, alice: alice} do
    assert {:ok, registration} = OAuthRegistrations.register(oauth_manifest())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    verifier = String.duplicate("v", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert {:ok, code} =
             OAuth.create_authorization_code(
               application,
               alice,
               "https://writer.example/oauth/callback",
               "read write",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:ok, _token} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => code.code,
               "client_id" => application.client_id,
               "client_secret" => application.client_secret,
               "redirect_uri" => "https://writer.example/oauth/callback",
               "code_verifier" => verifier
             })

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/settings/privacy")
    assert has_element?(view, "#oauth-grant-#{registration.id}")

    view
    |> element(
      "button[data-role='privacy-revoke-oauth'][phx-value-origin='https://writer.example']"
    )
    |> render_click()

    refute OAuthRegistrations.active_user_grant?("https://writer.example", alice.id)
    refute has_element?(view, "#oauth-grant-#{registration.id}")
  end

  test "lists and revokes transactional mini-app message consent independently", %{
    conn: conn,
    alice: alice
  } do
    assert {:ok, _declaration, :created} = Declarations.ensure(notification_manifest())

    assert {:ok, consent} =
             NotificationConsents.decide(alice.id, "https://alerts.example", :granted)

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/settings/privacy")

    assert has_element?(view, "#notification-consent-#{consent.id}")
    assert has_element?(view, "#notification-consent-#{consent.id}", consent.app_actor_url)

    view
    |> element(
      "button[data-role='privacy-revoke-notifications'][phx-value-origin='https://alerts.example']"
    )
    |> render_click()

    assert NotificationConsents.state(alice.id, "https://alerts.example") == :prompt
    refute has_element?(view, "#notification-consent-#{consent.id}")
  end

  test "lists blocks and mutes for the current user", %{
    conn: conn,
    alice: alice,
    mute: mute,
    block: block
  } do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/settings/privacy")

    assert has_element?(view, "#mute-#{mute.id}")
    assert has_element?(view, "#mute-#{mute.id} [data-role='privacy-target-handle']", "@bob")
    assert has_element?(view, "#block-#{block.id}")
    assert has_element?(view, "#block-#{block.id} [data-role='privacy-target-handle']", "@carol")
  end

  test "mutes can be removed from the privacy screen", %{conn: conn, alice: alice, mute: mute} do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/settings/privacy")

    assert has_element?(view, "#mute-#{mute.id}")

    view
    |> element("button[data-role='privacy-unmute'][phx-value-id='#{mute.id}']")
    |> render_click()

    assert Relationships.get(mute.id) == nil
    refute has_element?(view, "#mute-#{mute.id}")
  end

  test "blocks can be removed from the privacy screen", %{conn: conn, alice: alice, block: block} do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/settings/privacy")

    assert has_element?(view, "#block-#{block.id}")

    view
    |> element("button[data-role='privacy-unblock'][phx-value-id='#{block.id}']")
    |> render_click()

    assert Relationships.get(block.id) == nil
    refute has_element?(view, "#block-#{block.id}")
  end

  test "signed-out users are prompted to sign in", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings/privacy")
    assert has_element?(view, "[data-role='privacy-auth-required']")
  end

  defp wallet_manifest do
    attrs = %{
      "version" => "1",
      "name" => "Wallet App",
      "homeUrl" => "https://wallet.example/",
      "wallet" => %{
        "evm" => %{"enabled" => true, "required" => false, "requiredChains" => []}
      },
      "capabilities" => []
    }

    assert {:ok, manifest} =
             Manifest.decode(
               Jason.encode!(attrs),
               "https://wallet.example/.well-known/fediverse-miniapp.json"
             )

    manifest
  end

  defp oauth_manifest do
    attrs = %{
      "version" => "1",
      "name" => "Writer App",
      "homeUrl" => "https://writer.example/",
      "oauth" => %{
        "redirectUris" => ["https://writer.example/oauth/callback"],
        "scopes" => ["read", "write"]
      },
      "capabilities" => ["compose_note"]
    }

    assert {:ok, manifest} =
             Manifest.decode(
               Jason.encode!(attrs),
               "https://writer.example/.well-known/fediverse-miniapp.json"
             )

    manifest
  end

  defp notification_manifest do
    attrs = %{
      "version" => "1",
      "name" => "Alerts App",
      "homeUrl" => "https://alerts.example/",
      "oauth" => %{
        "redirectUris" => ["https://alerts.example/oauth/callback"],
        "scopes" => ["read"]
      },
      "activityPub" => %{
        "actorUrl" => "https://alerts.example/ap/actor",
        "publicNotes" => true,
        "transactionalMentions" => true
      },
      "capabilities" => []
    }

    assert {:ok, manifest} =
             Manifest.decode(
               Jason.encode!(attrs),
               "https://alerts.example/.well-known/fediverse-miniapp.json"
             )

    manifest
  end
end
