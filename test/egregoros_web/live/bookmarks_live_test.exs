defmodule EgregorosWeb.BookmarksLiveTest do
  use EgregorosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Egregoros.Activities.Note
  alias Egregoros.Interactions
  alias Egregoros.Pipeline
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
end
