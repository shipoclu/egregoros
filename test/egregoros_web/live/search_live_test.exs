defmodule EgregorosWeb.SearchLiveTest do
  use EgregorosWeb.ConnCase, async: true

  import Mox
  import Phoenix.LiveViewTest

  alias Egregoros.Activities.Note
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Publish
  alias Egregoros.Relationships
  alias Egregoros.TestSupport.Fixtures
  alias Egregoros.Users

  test "empty search shows guidance copy", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/search")

    assert has_element?(view, "[data-role='search-results']", "Type a query")
    refute has_element?(view, "[data-role='search-post-results']")
  end

  test "search form patches to the canonical query url", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/search")

    view
    |> form("#search-form", search: %{q: "bo"})
    |> render_submit()

    assert_patch(view, "/search?q=bo")

    view
    |> form("#search-form", search: %{q: ""})
    |> render_submit()

    assert_patch(view, "/search")
  end

  test "searching by query lists matching accounts", %{conn: conn} do
    {:ok, _} = Users.create_local_user("alice")
    {:ok, _} = Users.create_local_user("bob")

    {:ok, view, _html} = live(conn, "/search?q=bo")

    assert has_element?(view, "[data-role='search-results']")
    assert has_element?(view, "[data-role='search-result-handle']", "@bob")
    refute has_element?(view, "[data-role='search-result-handle']", "@alice")
  end

  test "searching by query lists matching posts", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    assert {:ok, _} = Pipeline.ingest(Note.build(user, "Hello from search"), local: true)
    assert {:ok, _} = Pipeline.ingest(Note.build(user, "No match here"), local: true)

    {:ok, view, _html} = live(conn, "/search?q=hello")

    assert has_element?(view, "[data-role='search-post-results']")
    assert has_element?(view, "[data-role='status-card']", "Hello from search")
    refute has_element?(view, "[data-role='status-card']", "No match here")
  end

  test "searching by query does not include direct messages", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    assert {:ok, _} = Pipeline.ingest(Note.build(user, "Public hello"), local: true)

    dm =
      user
      |> Note.build("Secret hello")
      |> Map.put("to", [])
      |> Map.put("cc", [])

    assert {:ok, _} = Pipeline.ingest(dm, local: true)

    {:ok, view, _html} = live(conn, "/search?q=secret")

    assert has_element?(view, "[data-role='search-post-results']")
    refute has_element?(view, "[data-role='status-card']", "Secret hello")
  end

  test "searching for a hashtag shows a tag quick link", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    assert {:ok, _} = Publish.post_note(user, "Hello #elixir")

    {:ok, view, _html} = live(conn, "/search?q=%23elixir")

    assert has_element?(view, "[data-role='search-tag-results']")
    assert has_element?(view, "[data-role='search-tag-link'][href='/tags/elixir']", "#elixir")
  end

  test "searching without # still suggests a matching tag", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    assert {:ok, _} = Publish.post_note(user, "Hello #elixir")

    {:ok, view, _html} = live(conn, "/search?q=elixir")

    assert has_element?(view, "[data-role='search-tag-results']")
    assert has_element?(view, "[data-role='search-tag-link'][href='/tags/elixir']", "#elixir")
  end

  test "search does not suggest tags for remote handles", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    assert {:ok, _} = Publish.post_note(user, "Hello #bob")

    {:ok, view, _html} = live(conn, "/search?q=bob@remote.example")

    assert has_element?(view, "[data-role='remote-follow']")
    refute has_element?(view, "[data-role='search-tag-results']")
  end

  test "signed-out users are prompted to login before following remote handles", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/search?q=bob@remote.example")

    assert has_element?(view, "[data-role='remote-follow']", "Login to follow")
    refute has_element?(view, "button[data-role='remote-follow-button']")
  end

  test "search renders a remote-follow already-following state", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    {:ok, remote} =
      Users.create_user(%{
        nickname: "bob",
        domain: "remote.example",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    {:ok, _} =
      Relationships.upsert_relationship(%{
        type: "Follow",
        actor: user.ap_id,
        object: remote.ap_id,
        activity_ap_id: nil
      })

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/search?q=bob@remote.example")

    assert has_element?(view, "[data-role='remote-follow']", "You are following")
    refute has_element?(view, "button[data-role='remote-follow-button']")
  end

  test "reply buttons dispatch reply modal events without navigation", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    assert {:ok, _} = Pipeline.ingest(Note.build(user, "Reply target"), local: true)
    [note] = Objects.list_notes()

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/search?q=reply")

    assert has_element?(view, "#reply-modal[data-role='reply-modal'][data-state='closed']")
    assert has_element?(view, "#search-post-#{note.id} button[data-role='reply']")

    html =
      view
      |> element("#search-post-#{note.id} button[data-role='reply']")
      |> render()

    assert html =~ "egregoros:reply-open"
    assert html =~ note.ap_id
    refute html =~ "?reply=true"
  end

  test "signed-in users can reply from search results", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    assert {:ok, parent} = Pipeline.ingest(Note.build(user, "Parent post"), local: true)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/search?q=parent")

    view
    |> element("#search-post-#{parent.id} button[data-role='reply']")
    |> render_click()

    view
    |> form("#reply-modal-form", reply: %{content: "A reply"})
    |> render_submit()

    [reply] = Objects.list_replies_to(parent.ap_id, limit: 1)
    assert reply.data["inReplyTo"] == parent.ap_id
  end

  test "search shows a no-results state for accounts and posts", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/search?q=nomatch")

    assert has_element?(view, "[data-role='search-results']", "No matching accounts")
    assert has_element?(view, "[data-role='search-post-results']")
    assert has_element?(view, "[data-role='search-post-results']", "No matching posts")
  end

  test "signed-in users can like and bookmark posts from search results", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    assert {:ok, _note} = Pipeline.ingest(Note.build(user, "Hello from search"), local: true)
    [note] = Objects.list_notes()

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/search?q=hello")

    refute has_element?(view, "#search-post-#{note.id} button[data-role='like']", "Unlike")

    view
    |> element("#search-post-#{note.id} button[data-role='like']")
    |> render_click()

    assert has_element?(view, "#search-post-#{note.id} button[data-role='like']", "Unlike")

    refute has_element?(
             view,
             "#search-post-#{note.id} button[data-role='bookmark']",
             "Unbookmark"
           )

    view
    |> element("#search-post-#{note.id} button[data-role='bookmark']")
    |> render_click()

    assert has_element?(
             view,
             "#search-post-#{note.id} button[data-role='bookmark']",
             "Unbookmark"
           )
  end

  test "logged-in users can follow remote accounts by handle", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    expect(Egregoros.HTTP.Mock, :get, 0, fn _url, _headers -> :ok end)
    expect(Egregoros.HTTP.Mock, :post, 0, fn _url, _body, _headers -> :ok end)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, "/search?q=bob@remote.example")

    assert has_element?(view, "[data-role='remote-follow']")

    view
    |> element("button[data-role='remote-follow-button']")
    |> render_click()

    assert render(view) =~ "Queued follow request for @bob@remote.example."
    assert has_element?(view, "[data-role='remote-follow']", "Remote follow queued")

    assert Enum.any?(all_enqueued(), fn job ->
             job.worker == "Egregoros.Workers.FollowRemote"
           end)
  end

  test "follow remote shows a flash error when invoked while signed out", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/search?q=bob@remote.example")

    _html = render_click(view, "follow_remote", %{})

    assert render(view) =~ "Login to follow remote accounts."
  end

  test "follow remote shows a flash error when the handle is unsafe", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    expect(Egregoros.HTTP.Mock, :get, 0, fn _url, _headers -> :ok end)
    expect(Egregoros.HTTP.Mock, :post, 0, fn _url, _body, _headers -> :ok end)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/search?q=bob@127.0.0.1")

    view
    |> element("button[data-role='remote-follow-button']")
    |> render_click()

    assert render(view) =~ "Could not follow remote account."
  end

  test "search reply modal supports mention suggestions and can clear them", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    {:ok, _} = Users.create_local_user("bob")

    assert {:ok, parent} = Pipeline.ingest(Note.build(user, "Reply target"), local: true)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/search?q=reply")

    assert has_element?(view, "#reply-modal[data-role='reply-modal'][data-state='closed']")

    _html =
      render_click(view, "open_reply_modal", %{
        "in_reply_to" => parent.ap_id,
        "actor_handle" => "@alice"
      })

    assert has_element?(view, "#reply-modal[data-role='reply-modal'][data-state='open']")

    _html = render_hook(view, "mention_search", %{"q" => "bo", "scope" => "reply-modal"})
    assert has_element?(view, "[data-role='mention-suggestion']", "@bob")

    _html = render_hook(view, "mention_clear", %{"scope" => "reply-modal"})
    refute has_element?(view, "[data-role='mention-suggestion']")
  end

  test "search reply modal can be opened, updated, and closed without navigation", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    assert {:ok, parent} = Pipeline.ingest(Note.build(user, "Reply target"), local: true)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/search?q=reply")

    _html =
      render_click(view, "open_reply_modal", %{
        "in_reply_to" => parent.ap_id,
        "actor_handle" => "@alice"
      })

    assert has_element?(view, "[data-role='compose-options'][data-state='closed']")

    _html =
      render_change(view, "reply_change", %{
        "reply" => %{"ui_options_open" => "true", "spoiler_text" => "cw"}
      })

    assert has_element?(view, "[data-role='compose-options'][data-state='open']")
    assert has_element?(view, "[data-role='compose-cw'][data-state='open']")

    _html = render_click(view, "toggle_reply_cw", %{})
    assert has_element?(view, "[data-role='compose-cw'][data-state='closed']")

    _html = render_click(view, "close_reply_modal", %{})

    assert has_element?(view, "#reply-modal[data-role='reply-modal'][data-state='closed']")
  end

  test "signed-out users cannot post replies from search results", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/search?q=reply")

    _html =
      render_click(view, "create_reply", %{
        "reply" => %{"content" => "hello", "in_reply_to" => "https://example.com/objects/1"}
      })

    assert render(view) =~ "Register to reply."
  end

  test "replying requires selecting a post to reply to", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/search?q=reply")

    view
    |> form("#reply-modal-form", reply: %{content: "hello"})
    |> render_submit()

    assert render(view) =~ "Select a post to reply to."
  end

  test "replying rejects content longer than 5000 characters from search results", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    assert {:ok, parent} = Pipeline.ingest(Note.build(user, "Reply target"), local: true)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/search?q=reply")

    _html =
      render_click(view, "open_reply_modal", %{
        "in_reply_to" => parent.ap_id,
        "actor_handle" => "@alice"
      })

    too_long = String.duplicate("a", 5001)

    view
    |> form("#reply-modal-form", reply: %{content: too_long})
    |> render_submit()

    assert render(view) =~ "Reply is too long."
    assert Objects.list_replies_to(parent.ap_id, limit: 10) == []
  end

  test "replying rejects empty replies from search results", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    assert {:ok, parent} = Pipeline.ingest(Note.build(user, "Reply target"), local: true)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/search?q=reply")

    _html =
      render_click(view, "open_reply_modal", %{
        "in_reply_to" => parent.ap_id,
        "actor_handle" => "@alice"
      })

    view
    |> form("#reply-modal-form", reply: %{content: ""})
    |> render_submit()

    assert render(view) =~ "Reply can&#39;t be empty."
    assert Objects.list_replies_to(parent.ap_id, limit: 10) == []
  end

  test "replying surfaces upload failures for attachments from search results", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    assert {:ok, parent} = Pipeline.ingest(Note.build(user, "Reply target"), local: true)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/search?q=reply")

    _html =
      render_click(view, "open_reply_modal", %{
        "in_reply_to" => parent.ap_id,
        "actor_handle" => "@alice"
      })

    fixture_path = Fixtures.path!("DSCN0010.png")
    content = File.read!(fixture_path)

    upload =
      file_input(view, "#reply-modal-form", :reply_media, [
        %{
          last_modified: 1_694_171_879_000,
          name: "photo.png",
          content: content,
          size: byte_size(content),
          type: "image/png"
        }
      ])

    expect(Egregoros.MediaStorage.Mock, :store_media, fn passed_user, passed_upload ->
      assert passed_user.id == user.id
      assert passed_upload.filename == "photo.png"
      {:error, :upload_failed}
    end)

    assert render_upload(upload, "photo.png") =~ "100%"

    view
    |> form("#reply-modal-form", reply: %{content: "Reply with media"})
    |> render_submit()

    assert render(view) =~ "Could not upload attachment."
    assert Objects.list_replies_to(parent.ap_id, limit: 10) == []
  end

  test "signed-in users can repost and react to posts from search results", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    assert {:ok, _note} = Pipeline.ingest(Note.build(user, "Hello from search"), local: true)
    [note] = Objects.list_notes()

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/search?q=hello")

    view
    |> element("#search-post-#{note.id} button[data-role='repost']")
    |> render_click()

    assert Objects.get_by_type_actor_object("Announce", user.ap_id, note.ap_id)

    view
    |> element("#search-post-#{note.id} button[data-role='reaction'][data-emoji='🔥']")
    |> render_click()

    assert Objects.get_emoji_react(user.ap_id, note.ap_id, "🔥")
  end

  test "signed-in users can delete their own posts from search results", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    assert {:ok, _} = Pipeline.ingest(Note.build(user, "Delete me"), local: true)
    [note] = Objects.list_notes()

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/search?q=delete")

    assert has_element?(view, "#search-post-#{note.id} button[data-role='delete-post']")

    view
    |> element("#search-post-#{note.id} button[data-role='delete-post-confirm']")
    |> render_click()

    assert Objects.get(note.id) == nil
    assert render(view) =~ "Deleted post."
  end

  test "search refreshes statuses after interactions and drops now-invisible results", %{
    conn: conn
  } do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")

    assert {:ok, public_note} =
             Pipeline.ingest(Note.build(bob, "Visible"), local: true)

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/search?q=visible")

    assert has_element?(view, "#search-post-#{public_note.id}", "Visible")

    assert {:ok, _} =
             Objects.update_object(public_note, %{
               data: Map.merge(public_note.data, %{"to" => [bob.ap_id], "cc" => []})
             })

    view
    |> element("#search-post-#{public_note.id} button[data-role='like']")
    |> render_click()

    refute has_element?(view, "#search-post-#{public_note.id}")
  end

  test "toggle events ignore invalid ids", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/search?q=hello")

    _html = render_click(view, "toggle_like", %{"id" => "not-an-int"})
    _html = render_click(view, "toggle_reaction", %{"id" => "123", "emoji" => nil})
  end
end
