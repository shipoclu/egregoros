defmodule EgregorosWeb.MessagesLiveTest do
  use EgregorosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Egregoros.DirectMessages
  alias Egregoros.E2EE
  alias Egregoros.Keys
  alias Egregoros.Publish
  alias Egregoros.Users
  alias EgregorosWeb.URL

  setup do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    {:ok, carol} = Users.create_local_user("carol")

    %{alice: alice, bob: bob, carol: carol}
  end

  test "renders a sign-in prompt for guests", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "[data-role='messages-auth-required']")
  end

  test "guest events are ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "[data-role='messages-auth-required']")

    _html = render_click(view, "new_chat", %{})
    _html = render_click(view, "select_conversation", %{})
    _html = render_click(view, "select_conversation", %{"peer" => ""})

    send(view.pid, {:post_created, %{}})
    _html = render(view)

    assert has_element?(view, "[data-role='messages-auth-required']")
  end

  test "incoming DMs from a different peer do not replace the open thread", %{
    conn: conn,
    alice: alice,
    bob: bob,
    carol: carol
  } do
    {:ok, _} = Publish.post_note(bob, "@alice DM from bob", visibility: "direct")

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "[data-role='dm-chat-peer-handle']", "@bob")
    assert has_element?(view, "[data-role='dm-message-body']", "DM from bob")

    {:ok, _} = Publish.post_note(carol, "@alice DM from carol", visibility: "direct")
    [carol_dm] = DirectMessages.list_conversation(alice, carol.ap_id, limit: 1)

    send(view.pid, {:post_created, carol_dm})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "[data-role='dm-conversation'][data-peer-handle='@carol']")
    assert has_element?(view, "[data-role='dm-chat-peer-handle']", "@bob")
    refute has_element?(view, "[data-role='dm-message-body']", "DM from carol")
  end

  test "malformed message events do not crash signed-in sessions", %{conn: conn, alice: alice} do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    _html = render_change(view, "dm_change", %{})
    _html = render_click(view, "pick_recipient", %{})
    _html = render_click(view, "send_dm", %{})

    view
    |> form("#dm-form", dm: %{recipient: "@#{alice.nickname}", content: "hello me"})
    |> render_submit()

    assert [_dm] = DirectMessages.list_for_user(alice, limit: 1)
    assert has_element?(view, "#dm-form")
  end

  test "sending a DM requires picking a recipient", %{conn: conn, alice: alice} do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    view
    |> form("#dm-form", dm: %{recipient: "", content: "hello"})
    |> render_submit()

    assert render(view) =~ "Pick a recipient."
  end

  test "sending a DM rejects empty content", %{conn: conn, alice: alice} do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    view
    |> form("#dm-form", dm: %{recipient: "@#{alice.nickname}", content: ""})
    |> render_submit()

    assert render(view) =~ "Message can&#39;t be empty."
  end

  test "invalid dm events are ignored in partial state", %{conn: conn, alice: alice} do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    _html = render_click(view, "load_more_conversations", %{})
    _html = render_click(view, "load_older_messages", %{})
    _html = render_click(view, "pick_recipient", %{"ap_id" => "", "handle" => ""})

    assert has_element?(view, "#dm-form")
  end

  test "shows conversations and selects the newest by default", %{
    conn: conn,
    alice: alice,
    bob: bob,
    carol: carol
  } do
    {:ok, _} = Publish.post_note(bob, "@alice DM from bob", visibility: "direct")
    {:ok, _} = Publish.post_note(carol, "@alice DM from carol", visibility: "direct")

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "[data-role='dm-conversations']")
    assert has_element?(view, "[data-role='dm-conversation'][data-peer-handle='@bob']")
    assert has_element?(view, "[data-role='dm-conversation'][data-peer-handle='@carol']")

    assert has_element?(view, "[data-role='dm-chat-peer-handle']", "@carol")
    assert has_element?(view, "[data-role='dm-message-body']", "DM from carol")
    refute has_element?(view, "[data-role='dm-message-body']", "DM from bob")
    refute has_element?(view, "[data-role='dm-e2ee-badge']")
  end

  test "selecting a conversation loads that thread", %{
    conn: conn,
    alice: alice,
    bob: bob,
    carol: carol
  } do
    {:ok, _} = Publish.post_note(bob, "@alice DM from bob", visibility: "direct")
    {:ok, _} = Publish.post_note(carol, "@alice DM from carol", visibility: "direct")

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    view
    |> element("[data-role='dm-conversation'][data-peer-handle='@bob']")
    |> render_click()

    assert has_element?(view, "[data-role='dm-chat-peer-handle']", "@bob")
    assert has_element?(view, "[data-role='dm-message-body']", "DM from bob")
    refute has_element?(view, "[data-role='dm-message-body']", "DM from carol")
  end

  test "selecting a conversation with no history shows an empty thread", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    _html = render_click(view, "select_conversation", %{"peer" => bob.ap_id})

    assert has_element?(view, "[data-role='dm-chat-peer-handle']", "@#{bob.nickname}")
    refute has_element?(view, "[data-role='dm-message-body']")
  end

  test "new chat clears the selected conversation and shows the recipient field", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    {:ok, _} = Publish.post_note(bob, "@alice DM from bob", visibility: "direct")

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "[data-role='dm-chat-peer-handle']", "@bob")

    view
    |> element("[data-role='dm-new-chat']")
    |> render_click()

    refute has_element?(view, "[data-role='dm-chat-peer-handle']")
    assert has_element?(view, "input[data-role='dm-recipient'][type='text']")
  end

  test "picking a recipient opens an empty conversation when there is no history", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    refute has_element?(view, "[data-role='dm-chat-peer-handle']")
    assert has_element?(view, "input[data-role='dm-recipient'][type='text']")

    _html =
      view
      |> form("#dm-form", dm: %{recipient: "@#{bob.nickname}", content: ""})
      |> render_change()

    assert has_element?(view, "[data-role='dm-recipient-suggestions']")

    view
    |> element("[data-role='dm-recipient-suggestion'][data-handle='@#{bob.nickname}']")
    |> render_click()

    assert has_element?(view, "[data-role='dm-chat-peer-handle']", "@#{bob.nickname}")
    refute has_element?(view, "[data-role='dm-message-body']")
  end

  test "picking a recipient with an existing conversation loads that thread", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    {:ok, _} = Publish.post_note(bob, "@#{alice.nickname} DM from bob", visibility: "direct")

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "[data-role='dm-chat-peer-handle']", "@#{bob.nickname}")
    assert has_element?(view, "[data-role='dm-message-body']", "DM from bob")

    view
    |> element("[data-role='dm-new-chat']")
    |> render_click()

    assert has_element?(view, "input[data-role='dm-recipient'][type='text']")

    _html =
      view
      |> form("#dm-form", dm: %{recipient: "@#{bob.nickname}", content: ""})
      |> render_change()

    view
    |> element("[data-role='dm-recipient-suggestion'][data-handle='@#{bob.nickname}']")
    |> render_click()

    assert has_element?(view, "[data-role='dm-chat-peer-handle']", "@#{bob.nickname}")
    assert has_element?(view, "[data-role='dm-message-body']", "DM from bob")
  end

  test "sending a DM inserts it into the current conversation", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    {:ok, _} = Publish.post_note(bob, "@alice DM from bob", visibility: "direct")

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    view
    |> element("[data-role='dm-conversation'][data-peer-handle='@bob']")
    |> render_click()

    view
    |> form("#dm-form", dm: %{recipient: "@#{bob.nickname}", content: "hi bob"})
    |> render_submit()

    refute has_element?(view, "#flash-info")
    assert has_element?(view, "[data-role='dm-message'][data-kind='sent']")
    assert has_element?(view, "[data-role='dm-message-body']", "hi bob")
  end

  test "send button does not blank itself via phx-disable-with", %{conn: conn, alice: alice} do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    refute has_element?(view, "button[aria-label='Send message'][phx-disable-with='']")
  end

  test "chat window uses a DMChatScroller hook", %{conn: conn, alice: alice} do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "#dm-chat-messages[phx-hook='DMChatScroller']")
  end

  test "dm composer exposes the selected peer ap id", %{conn: conn, alice: alice, bob: bob} do
    {:ok, _} = Publish.post_note(bob, "@alice hi", visibility: "direct")

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "#dm-form[data-peer-ap-id='#{bob.ap_id}']")
  end

  test "renders avatar images when available", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    {:ok, _} = Users.update_profile(alice, %{"avatar_url" => "https://cdn.example/alice.png"})
    {:ok, _} = Users.update_profile(bob, %{"avatar_url" => "https://cdn.example/bob.png"})

    {:ok, _} = Publish.post_note(bob, "@alice DM from bob", visibility: "direct")
    {:ok, _} = Publish.post_note(alice, "@bob DM from alice", visibility: "direct")

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(
             view,
             "[data-role='dm-conversation'][data-peer-handle='@bob'] img[src='https://cdn.example/bob.png']"
           )

    assert has_element?(view, "img[src='https://cdn.example/bob.png']")
    assert has_element?(view, "img[src='https://cdn.example/alice.png']")
  end

  test "uses uploads_base_url for the current user avatar in chat messages", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    avatar_path = "/uploads/avatars/#{alice.id}/avatar.png"
    {:ok, _} = Users.update_profile(alice, %{"avatar_url" => avatar_path})

    {:ok, _} = Publish.post_note(alice, "@#{bob.nickname} dm-from-alice", visibility: "direct")

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    expected = URL.absolute(avatar_path, alice.ap_id)

    assert has_element?(view, "img[src='#{expected}']")
  end

  test "sending an encrypted DM stores the payload and renders unlock controls", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    payload = %{
      "version" => 1,
      "alg" => "ECDH-P256+HKDF-SHA256+AES-256-GCM",
      "sender" => %{"ap_id" => alice.ap_id, "kid" => "e2ee-alice"},
      "recipient" => %{"ap_id" => bob.ap_id, "kid" => "e2ee-bob"},
      "nonce" => "nonce",
      "salt" => "salt",
      "aad" => %{
        "sender_ap_id" => alice.ap_id,
        "recipient_ap_id" => bob.ap_id,
        "sender_kid" => "e2ee-alice",
        "recipient_kid" => "e2ee-bob"
      },
      "ciphertext" => "ciphertext"
    }

    view
    |> form("#dm-form",
      dm: %{
        recipient: "@#{bob.nickname}",
        content: "this-should-not-be-stored",
        e2ee_dm: Jason.encode!(payload)
      }
    )
    |> render_submit()

    assert has_element?(view, "[data-role='e2ee-dm-body']", "[Encrypted]")
    assert has_element?(view, "[data-role='e2ee-dm-decrypting']")
    refute has_element?(view, "[data-role='dm-message-body']", "this-should-not-be-stored")

    assert has_element?(view, "[data-role='dm-e2ee-badge']")
    assert has_element?(view, "[data-role='e2ee-dm-unlock']")

    [dm] = DirectMessages.list_conversation(alice, bob.ap_id, limit: 1)
    assert dm.type == "EncryptedMessage"
    assert dm.data["egregoros:e2ee_dm"] == payload
    refute dm.data["source"]["content"] =~ "this-should-not-be-stored"
  end

  test "conversation list shows preview, timestamp, and unread state", %{
    conn: conn,
    alice: alice,
    bob: bob,
    carol: carol
  } do
    {:ok, _} = Publish.post_note(bob, "@alice DM from bob", visibility: "direct")
    {:ok, _} = Publish.post_note(carol, "@alice DM from carol", visibility: "direct")

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(
             view,
             "[data-role='dm-conversation'][data-peer-handle='@bob'] [data-role='dm-conversation-preview']",
             "DM from bob"
           )

    assert has_element?(
             view,
             "[data-role='dm-conversation'][data-peer-handle='@bob'] [data-role='dm-conversation-time']"
           )

    assert has_element?(
             view,
             "[data-role='dm-conversation'][data-peer-handle='@bob'] [data-role='dm-conversation-unread']"
           )

    refute has_element?(
             view,
             "[data-role='dm-conversation'][data-peer-handle='@carol'] [data-role='dm-conversation-unread']"
           )

    view
    |> element("[data-role='dm-conversation'][data-peer-handle='@bob']")
    |> render_click()

    refute has_element?(
             view,
             "[data-role='dm-conversation'][data-peer-handle='@bob'] [data-role='dm-conversation-unread']"
           )
  end

  test "conversation list E2EE indicator depends on the last message", %{
    conn: conn,
    alice: alice,
    bob: bob,
    carol: carol
  } do
    {:ok, _} =
      Publish.post_note(bob, "@alice Encrypted message",
        visibility: "direct",
        e2ee_dm: e2ee_payload(bob, alice)
      )

    {:ok, _} = Publish.post_note(bob, "@alice DM from bob", visibility: "direct")

    {:ok, _} =
      Publish.post_note(carol, "@alice Encrypted message",
        visibility: "direct",
        e2ee_dm: e2ee_payload(carol, alice)
      )

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    refute has_element?(
             view,
             "[data-role='dm-conversation'][data-peer-handle='@bob'] [data-role='dm-conversation-e2ee']"
           )

    assert has_element?(
             view,
             "[data-role='dm-conversation'][data-peer-handle='@carol'] [data-role='dm-conversation-e2ee']"
           )
  end

  defp e2ee_payload(sender, recipient) do
    %{
      "version" => 1,
      "alg" => "ECDH-P256+HKDF-SHA256+AES-256-GCM",
      "sender" => %{"ap_id" => sender.ap_id, "kid" => "e2ee-#{sender.nickname}"},
      "recipient" => %{"ap_id" => recipient.ap_id, "kid" => "e2ee-#{recipient.nickname}"},
      "nonce" => "nonce",
      "salt" => "salt",
      "aad" => %{
        "sender_ap_id" => sender.ap_id,
        "recipient_ap_id" => recipient.ap_id,
        "sender_kid" => "e2ee-#{sender.nickname}",
        "recipient_kid" => "e2ee-#{recipient.nickname}"
      },
      "ciphertext" => "ciphertext"
    }
  end

  defp enable_e2ee_key!(user) do
    kid = "e2ee-#{System.unique_integer([:positive])}"

    public_key_jwk = %{
      "kty" => "EC",
      "crv" => "P-256",
      "x" => "pQECAwQFBgcICQoLDA0ODw",
      "y" => "AQIDBAUGBwgJCgsMDQ4PEA"
    }

    assert {:ok, _} =
             E2EE.enable_key_with_wrapper(user, %{
               kid: kid,
               public_key_jwk: public_key_jwk,
               wrapper: %{
                 type: "recovery_mnemonic_v1",
                 wrapped_private_key: <<1, 2, 3>>,
                 params: %{
                   "hkdf_salt" => Base.url_encode64("hkdf-salt", padding: false),
                   "iv" => Base.url_encode64("iv", padding: false),
                   "alg" => "A256GCM",
                   "kdf" => "HKDF-SHA256",
                   "info" => "egregoros:e2ee:wrap:mnemonic:v1"
                 }
               }
             })

    kid
  end

  test "recipient suggestions appear in a new chat and selecting one starts the chat", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "input[data-role='dm-recipient'][type='text']")

    view
    |> form("#dm-form", dm: %{recipient: "@#{bob.nickname}", content: ""})
    |> render_change()

    assert has_element?(view, "[data-role='dm-recipient-suggestions']")
    assert has_element?(view, "[data-role='dm-recipient-suggestion'][data-handle='@bob']")

    view
    |> element("[data-role='dm-recipient-suggestion'][data-handle='@bob']")
    |> render_click()

    assert has_element?(view, "[data-role='dm-chat-peer-handle']", "@bob")
    refute has_element?(view, "[data-role='dm-recipient-suggestions']")
    refute has_element?(view, "input[data-role='dm-recipient'][type='text']")
  end

  test "recipient suggestions include remote handles", %{conn: conn, alice: alice} do
    {public_key, _private_key} = Keys.generate_rsa_keypair()

    {:ok, _remote} =
      Users.create_user(%{
        nickname: "dave",
        ap_id: "https://remote.example/users/dave",
        inbox: "https://remote.example/users/dave/inbox",
        outbox: "https://remote.example/users/dave/outbox",
        public_key: public_key,
        local: false
      })

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    view
    |> form("#dm-form", dm: %{recipient: "@dave@remote.example", content: ""})
    |> render_change()

    assert has_element?(
             view,
             "[data-role='dm-recipient-suggestion'][data-handle='@dave@remote.example']"
           )
  end

  test "encrypt controls are hidden when the recipient does not support e2ee", %{
    conn: conn,
    alice: alice
  } do
    {public_key, _private_key} = Keys.generate_rsa_keypair()

    {:ok, remote} =
      Users.create_user(%{
        nickname: "dave",
        ap_id: "https://remote.example/users/dave",
        inbox: "https://remote.example/users/dave/inbox",
        outbox: "https://remote.example/users/dave/outbox",
        public_key: public_key,
        local: false
      })

    {:ok, _} =
      Publish.post_note(alice, "@dave@remote.example hello", visibility: "direct")

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      if url == remote.ap_id do
        {:ok, %{status: 200, body: %{"id" => remote.ap_id, "type" => "Person"}, headers: []}}
      else
        {:ok, %{status: 200, body: %{}, headers: []}}
      end
    end)

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "[data-role='dm-chat-peer-handle']", "@dave@remote.example")
    assert has_element?(view, "[data-role='dm-encrypt-enabled'][value='false']")
    refute has_element?(view, "[data-role='dm-encrypt-toggle']")
  end

  test "the DM encrypt toggle does not rely on backend events", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    _kid = enable_e2ee_key!(bob)

    {:ok, _} =
      Publish.post_note(bob, "@alice Encrypted message",
        visibility: "direct",
        e2ee_dm: e2ee_payload(bob, alice)
      )

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "[data-role='dm-encrypt-enabled'][value='true']")
    assert has_element?(view, "[data-role='dm-composer-lock']")
    assert has_element?(view, "[data-role='dm-encrypt-toggle']")
    refute has_element?(view, "[data-role='dm-encrypt-toggle'][phx-click]")

    refute render(view) =~ "toggle_dm_encrypt"
  end

  test "chat window preloads the peer's E2EE keys", %{conn: conn, alice: alice, bob: bob} do
    kid = enable_e2ee_key!(bob)
    {:ok, _} = Publish.post_note(bob, "@alice hi", visibility: "direct")

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "#dm-chat-messages[data-e2ee-peer-keys*='#{kid}']")
  end

  test "loads older messages in the current conversation", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    for i <- 1..41 do
      suffix = i |> Integer.to_string() |> String.pad_leading(3, "0")
      {:ok, _} = Publish.post_note(bob, "@alice dm-#{suffix}", visibility: "direct")
    end

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "[data-role='dm-load-older']")
    assert has_element?(view, "[data-role='dm-message-body']", "dm-041")
    refute has_element?(view, "[data-role='dm-message-body']", "dm-001")

    view
    |> element("[data-role='dm-load-older']")
    |> render_click()

    assert has_element?(view, "[data-role='dm-message-body']", "dm-001")
    refute has_element?(view, "[data-role='dm-load-older']")
  end

  test "loading older messages preserves conversation e2ee state when already enabled", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    _kid = enable_e2ee_key!(bob)

    for i <- 1..39 do
      suffix = i |> Integer.to_string() |> String.pad_leading(3, "0")
      {:ok, _} = Publish.post_note(bob, "@alice plain-#{suffix}", visibility: "direct")
    end

    {:ok, _} =
      Publish.post_note(bob, "@alice encrypted-newest",
        visibility: "direct",
        e2ee_dm: e2ee_payload(bob, alice)
      )

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "[data-role='dm-e2ee-badge']")
    assert has_element?(view, "[data-role='dm-load-older']")

    view
    |> element("[data-role='dm-load-older']")
    |> render_click()

    assert has_element?(view, "[data-role='dm-e2ee-badge']")
    refute has_element?(view, "[data-role='dm-load-older']")
  end

  test "loading older messages enables conversation e2ee when older messages are encrypted", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    _kid = enable_e2ee_key!(bob)

    {:ok, _} =
      Publish.post_note(bob, "@alice encrypted-oldest",
        visibility: "direct",
        e2ee_dm: e2ee_payload(bob, alice)
      )

    for i <- 1..40 do
      suffix = i |> Integer.to_string() |> String.pad_leading(3, "0")
      {:ok, _} = Publish.post_note(bob, "@alice plain-#{suffix}", visibility: "direct")
    end

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    refute has_element?(view, "[data-role='dm-e2ee-badge']")
    assert has_element?(view, "[data-role='dm-load-older']")

    view
    |> element("[data-role='dm-load-older']")
    |> render_click()

    assert has_element?(view, "[data-role='dm-e2ee-badge']")
    refute has_element?(view, "[data-role='dm-load-older']")
  end

  test "loads more conversations", %{conn: conn, alice: alice} do
    peers =
      Enum.map(1..41, fn i ->
        {:ok, user} = Users.create_local_user("peer#{i}")
        user
      end)

    Enum.each(peers, fn peer ->
      {:ok, _} =
        Publish.post_note(peer, "@alice hello from #{peer.nickname}", visibility: "direct")
    end)

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "[data-role='dm-load-more-conversations']")
    assert has_element?(view, "[data-role='dm-conversation'][data-peer-handle='@peer41']")
    refute has_element?(view, "[data-role='dm-conversation'][data-peer-handle='@peer1']")

    view
    |> element("[data-role='dm-load-more-conversations']")
    |> render_click()

    assert has_element?(view, "[data-role='dm-conversation'][data-peer-handle='@peer1']")
    refute has_element?(view, "[data-role='dm-load-more-conversations']")
  end
end
