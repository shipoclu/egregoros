defmodule EgregorosWeb.MessagesLiveTest do
  use EgregorosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Egregoros.DirectMessages
  alias Egregoros.Publish
  alias Egregoros.Users

  setup do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    %{alice: alice, bob: bob}
  end

  test "renders a sign-in prompt for guests", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "[data-role='messages-auth-required']")
  end

  test "lists direct messages visible to the signed-in user", %{conn: conn, alice: alice, bob: bob} do
    {:ok, _} = Publish.post_note(bob, "@alice Secret DM", visibility: "direct")

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "article", "Secret DM")
  end

  test "sending a DM inserts it into the list", %{conn: conn, alice: alice, bob: bob} do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    view
    |> form("#dm-form", dm: %{recipient: "@#{bob.nickname}", content: "hi bob"})
    |> render_submit()

    assert has_element?(view, "article", "hi bob")
  end

  test "sending an encrypted DM stores the payload and uses a placeholder body", %{
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

    assert has_element?(view, "article", "Encrypted message")
    refute has_element?(view, "article", "this-should-not-be-stored")

    [dm] = DirectMessages.list_for_user(alice, limit: 1)
    assert dm.data["egregoros:e2ee_dm"] == payload
  end
end
