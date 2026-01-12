defmodule EgregorosWeb.MessagesLiveTest do
  use EgregorosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Egregoros.DirectMessages
  alias Egregoros.Objects
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

  test "lists direct messages visible to the signed-in user", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
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

  test "sending a DM validates authentication, recipient, and body", %{conn: conn, bob: bob} do
    {:ok, view, _html} = live(conn, "/messages")

    _html =
      render_click(view, "send_dm", %{
        "dm" => %{"recipient" => "@#{bob.nickname}", "content" => "hi bob"}
      })

    assert has_element?(view, "[data-role='toast']", "Sign in to send messages.")

    {:ok, alice} = Users.create_local_user("alice2")
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    view
    |> form("#dm-form", dm: %{recipient: "", content: "hi bob"})
    |> render_submit()

    assert has_element?(view, "[data-role='toast']", "Pick a recipient.")

    view
    |> form("#dm-form", dm: %{recipient: "@#{bob.nickname}", content: ""})
    |> render_submit()

    assert has_element?(view, "[data-role='toast']", "Message can't be empty.")
  end

  test "messages include loading skeleton placeholders when more messages may load", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    Enum.each(1..21, fn idx ->
      assert {:ok, _} = Publish.post_note(bob, "@alice DM #{idx}", visibility: "direct")
    end)

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "[data-role='messages-loading-more']")

    assert has_element?(
             view,
             "[data-role='messages-loading-more'] [data-role='skeleton-status-card']"
           )
  end

  test "load_more appends messages and hides the load more controls at the end", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    Enum.each(1..21, fn idx ->
      assert {:ok, _} = Publish.post_note(bob, "@alice DM #{idx} end", visibility: "direct")
    end)

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "article", "DM 21 end")
    refute has_element?(view, "article", "DM 1 end")
    assert has_element?(view, "[data-role='messages-load-more']")

    _html = render_click(view, "load_more", %{})

    assert has_element?(view, "article", "DM 1 end")
    refute has_element?(view, "[data-role='messages-load-more']")
    refute has_element?(view, "[data-role='messages-loading-more']")
  end

  test "mention_search populates suggestions and mention_clear removes them", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    refute has_element?(view, "[data-role='compose-mention-suggestions']")

    _html =
      render_change(view, "mention_search", %{
        "q" => "@#{bob.nickname}",
        "scope" => "reply-modal"
      })

    assert has_element?(
             view,
             "[data-role='compose-mention-suggestions'] [data-role='mention-suggestion']",
             "@#{bob.nickname}"
           )

    _html = render_change(view, "mention_clear", %{"scope" => "reply-modal"})

    refute has_element?(view, "[data-role='compose-mention-suggestions']")
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

  test "open_reply_modal defaults to public visibility for non-DM parents", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    assert {:ok, create} = Publish.post_note(bob, "Public post", visibility: "public")
    parent = Objects.get_by_ap_id(create.object)

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    _html =
      render_click(view, "open_reply_modal", %{
        "in_reply_to" => parent.ap_id,
        "actor_handle" => "@#{bob.nickname}"
      })

    assert has_element?(view, "#reply-modal[data-role='reply-modal'][data-state='open']")
    assert has_element?(view, "#reply-modal [data-role='compose-visibility-label']", "Public")
  end

  test "messages reply modal can be opened and replies default to direct visibility", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    assert {:ok, create} = Publish.post_note(bob, "@alice Secret DM", visibility: "direct")
    parent = Objects.get_by_ap_id(create.object)

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "#reply-modal[data-role='reply-modal'][data-state='closed']")

    view
    |> element("#dm-#{parent.id} button[data-role='reply']")
    |> render_click()

    assert has_element?(view, "#reply-modal[data-role='reply-modal'][data-state='open']")
    assert has_element?(view, "#reply-modal [data-role='compose-visibility-label']", "Direct")

    view
    |> form("#reply-modal-form", reply: %{content: "Reply DM"})
    |> render_submit()

    assert render(view) =~ "Reply posted."

    [reply] = Objects.list_replies_to(parent.ap_id, limit: 1)
    assert reply.data["inReplyTo"] == parent.ap_id
    assert bob.ap_id in List.wrap(reply.data["to"])
  end

  test "create_reply fails with a helpful error when no target is selected", %{
    conn: conn,
    alice: alice
  } do
    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    view
    |> form("#reply-modal-form", reply: %{content: "Hi"})
    |> render_submit()

    assert render(view) =~ "Select a post to reply to."
  end

  test "create_reply rejects too-long replies", %{conn: conn, alice: alice, bob: bob} do
    assert {:ok, create} = Publish.post_note(bob, "@alice Secret DM", visibility: "direct")
    parent = Objects.get_by_ap_id(create.object)

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/messages")

    _html =
      render_click(view, "open_reply_modal", %{
        "in_reply_to" => parent.ap_id,
        "actor_handle" => "@#{bob.nickname}"
      })

    too_long = String.duplicate("a", 6000)

    view
    |> form("#reply-modal-form", reply: %{content: too_long})
    |> render_submit()

    assert render(view) =~ "Reply is too long."
    assert has_element?(view, "#reply-modal[data-role='reply-modal'][data-state='open']")
  end
end
