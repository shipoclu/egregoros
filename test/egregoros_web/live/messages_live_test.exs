defmodule EgregorosWeb.MessagesLiveTest do
  use EgregorosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Egregoros.DirectMessages
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

    assert has_element?(view, "[data-role='e2ee-dm-unlock']")

    [dm] = DirectMessages.list_conversation(alice, bob.ap_id, limit: 1)
    assert dm.type == "EncryptedMessage"
    assert dm.data["egregoros:e2ee_dm"] == payload
  end
end
