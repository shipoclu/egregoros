defmodule EgregorosWeb.BookmarksLiveTest do
  use EgregorosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Egregoros.Activities.Note
  alias Egregoros.Interactions
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users

  setup do
    {:ok, user} = Users.create_local_user("alice")
    %{user: user}
  end

  test "signed-out users are prompted to sign in", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/bookmarks")
    assert has_element?(view, "[data-role='bookmarks-auth-required']", "Sign in")

    {:ok, view, _html} = live(conn, "/favourites")
    assert has_element?(view, "[data-role='bookmarks-auth-required']", "Sign in")
  end

  test "shows an empty bookmarks state for signed-in users", %{conn: conn, user: user} do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/bookmarks")

    assert has_element?(view, "#bookmarks-empty", "No bookmarks yet.")
  end

  test "shows an empty favourites state for signed-in users", %{conn: conn, user: user} do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/favourites")

    assert has_element?(view, "#bookmarks-empty", "No favourites yet.")
  end

  test "bookmarks page shows bookmarked posts and allows unbookmarking", %{conn: conn, user: user} do
    {:ok, note} = Pipeline.ingest(Note.build(user, "Hello bookmarked"), local: true)
    assert {:ok, :bookmarked} = Interactions.toggle_bookmark(user, note.id)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/bookmarks")

    assert has_element?(view, "#post-#{note.id}", "Hello bookmarked")
    assert has_element?(view, "#post-#{note.id} button[data-role='bookmark']", "Unbookmark")

    view
    |> element("#post-#{note.id} button[data-role='bookmark']")
    |> render_click()

    refute has_element?(view, "#post-#{note.id}")
  end

  test "bookmarks reply modal can be opened and replies can be posted", %{conn: conn, user: user} do
    assert {:ok, parent} = Pipeline.ingest(Note.build(user, "Parent post"), local: true)
    assert {:ok, :bookmarked} = Interactions.toggle_bookmark(user, parent.id)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/bookmarks")

    assert has_element?(view, "#reply-modal[data-role='reply-modal'][data-state='closed']")

    view
    |> element("#post-#{parent.id} button[data-role='reply']")
    |> render_click()

    assert has_element?(view, "#reply-modal[data-role='reply-modal'][data-state='open']")

    view
    |> form("#reply-modal-form", reply: %{content: "A reply"})
    |> render_submit()

    assert render(view) =~ "Reply posted."

    [reply] = Objects.list_replies_to(parent.ap_id, limit: 1)
    assert reply.data["inReplyTo"] == parent.ap_id
  end

  test "favourites page lists liked posts and allows unliking", %{conn: conn, user: user} do
    {:ok, note} = Pipeline.ingest(Note.build(user, "Hello favourited"), local: true)
    assert {:ok, _} = Interactions.toggle_like(user, note.id)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/favourites")

    assert has_element?(view, "#post-#{note.id}", "Hello favourited")
    assert has_element?(view, "#post-#{note.id} button[data-role='like']", "Unlike")

    view
    |> element("#post-#{note.id} button[data-role='like']")
    |> render_click()

    refute has_element?(view, "#post-#{note.id}")
  end

  test "bookmarks page can load more saved posts", %{conn: conn, user: user} do
    [oldest | _rest] =
      for idx <- 1..25 do
        {:ok, note} = Pipeline.ingest(Note.build(user, "Bookmark #{idx}"), local: true)
        assert {:ok, :bookmarked} = Interactions.toggle_bookmark(user, note.id)
        note
      end

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/bookmarks")

    refute has_element?(view, "#post-#{oldest.id}")
    assert has_element?(view, "button[data-role='bookmarks-load-more']")

    view
    |> element("button[data-role='bookmarks-load-more']")
    |> render_click()

    assert has_element?(view, "#post-#{oldest.id}")
  end

  test "favourites page can load more liked posts", %{conn: conn, user: user} do
    [oldest | _rest] =
      for idx <- 1..25 do
        {:ok, note} = Pipeline.ingest(Note.build(user, "Favourite #{idx}"), local: true)
        assert {:ok, _} = Interactions.toggle_like(user, note.id)
        note
      end

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/favourites")

    refute has_element?(view, "#post-#{oldest.id}")
    assert has_element?(view, "button[data-role='bookmarks-load-more']")

    view
    |> element("button[data-role='bookmarks-load-more']")
    |> render_click()

    assert has_element?(view, "#post-#{oldest.id}")
  end

  test "copy link event shows a flash message", %{conn: conn, user: user} do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/bookmarks")

    _html = render_click(view, "copied_link", %{})

    assert render(view) =~ "Copied link to clipboard."
  end

  test "bookmarks page can toggle likes without removing the bookmarked post", %{
    conn: conn,
    user: user
  } do
    {:ok, note} = Pipeline.ingest(Note.build(user, "Hello bookmarked"), local: true)
    assert {:ok, :bookmarked} = Interactions.toggle_bookmark(user, note.id)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/bookmarks")

    refute Relationships.get_by_type_actor_object("Like", user.ap_id, note.ap_id)

    _html = render_click(view, "toggle_like", %{"id" => note.id})

    assert Relationships.get_by_type_actor_object("Like", user.ap_id, note.ap_id)
    assert has_element?(view, "#post-#{note.id}", "Hello bookmarked")
  end

  test "bookmarks page can toggle reposts", %{conn: conn, user: user} do
    {:ok, note} = Pipeline.ingest(Note.build(user, "Hello repost"), local: true)
    assert {:ok, :bookmarked} = Interactions.toggle_bookmark(user, note.id)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/bookmarks")

    refute Relationships.get_by_type_actor_object("Announce", user.ap_id, note.ap_id)

    _html = render_click(view, "toggle_repost", %{"id" => note.id})

    assert Relationships.get_by_type_actor_object("Announce", user.ap_id, note.ap_id)
  end

  test "bookmarks page can toggle emoji reactions", %{conn: conn, user: user} do
    {:ok, note} = Pipeline.ingest(Note.build(user, "Hello react"), local: true)
    assert {:ok, :bookmarked} = Interactions.toggle_bookmark(user, note.id)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/bookmarks")

    refute Relationships.get_by_type_actor_object("EmojiReact:🔥", user.ap_id, note.ap_id)

    _html = render_click(view, "toggle_reaction", %{"id" => note.id, "emoji" => "🔥"})

    assert Relationships.get_by_type_actor_object("EmojiReact:🔥", user.ap_id, note.ap_id)
  end

  test "signed-out bookmark pages reject like interactions" do
    {:ok, view, _html} = live(build_conn(), "/bookmarks")

    _html = render_click(view, "toggle_like", %{"id" => "123"})

    assert render(view) =~ "Register to like posts."
  end

  test "bookmark pages ignore invalid ids without crashing", %{conn: conn, user: user} do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/bookmarks")

    _html = render_click(view, "toggle_like", %{"id" => "nope"})

    refute render(view) =~ "Register to like posts."
  end

  test "delete_post shows an error when attempting to delete someone else's post", %{
    conn: conn,
    user: user
  } do
    {:ok, bob} = Users.create_local_user("bob")
    {:ok, note} = Pipeline.ingest(Note.build(bob, "Not yours"), local: true)

    assert {:ok, :bookmarked} = Interactions.toggle_bookmark(user, note.id)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/bookmarks")

    _html = render_click(view, "delete_post", %{"id" => note.id})

    assert render(view) =~ "Could not delete post."
    assert has_element?(view, "#post-#{note.id}", "Not yours")
  end
end
