defmodule EgregorosWeb.MessagesLiveTest do
  use EgregorosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Egregoros.DirectMessages
  alias Egregoros.Keys
  alias Egregoros.Publish
  alias Egregoros.Users

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

    assert has_element?(view, "[data-role='dm-message'][data-kind='sent']")
    assert has_element?(view, "[data-role='dm-message-body']", "hi bob")
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

    assert has_element?(view, "[data-role='dm-message-body']", "Encrypted message")
    refute has_element?(view, "[data-role='dm-message-body']", "this-should-not-be-stored")

    assert has_element?(view, "[data-role='dm-e2ee-badge']")
    assert has_element?(view, "[data-role='e2ee-dm-unlock']")

    [dm] = DirectMessages.list_conversation(alice, bob.ap_id, limit: 1)
    assert dm.type == "EncryptedMessage"
    assert dm.data["egregoros:e2ee_dm"] == payload
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

  test "the DM encrypt toggle is server authoritative", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    {:ok, _} =
      Publish.post_note(bob, "@alice Encrypted message",
        visibility: "direct",
        e2ee_dm: e2ee_payload(bob, alice)
      )

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "[data-role='dm-encrypt-enabled'][value='true']")
    assert has_element?(view, "[data-role='dm-composer-lock']")

    view
    |> element("[data-role='dm-encrypt-toggle']")
    |> render_click()

    assert has_element?(view, "[data-role='dm-encrypt-enabled'][value='false']")
    refute has_element?(view, "[data-role='dm-composer-lock']")
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
