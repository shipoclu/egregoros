defmodule EgregorosWeb.TagLiveTest do
  use EgregorosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Egregoros.Objects
  alias Egregoros.Publish
  alias Egregoros.Users

  setup do
    {:ok, user} = Users.create_local_user("alice")

    {:ok, create} = Publish.post_note(user, "Hello #elixir")
    note = Objects.get_by_ap_id(create.object)

    %{user: user, note: note}
  end

  test "signed-out tag pages use the public timeline href", %{conn: conn} do
    assert {:ok, view, _html} = live(conn, "/tags/elixir")

    assert has_element?(view, "a[href='/?timeline=public']", "Timeline")
    refute has_element?(view, "button[data-role='like']")
  end

  test "signed-in tag pages use the home timeline href", %{conn: conn, user: user} do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    assert {:ok, view, _html} = live(conn, "/tags/elixir")

    assert has_element?(view, "a[href='/?timeline=home']", "Timeline")
  end

  test "tag pages list matching posts", %{conn: conn} do
    assert {:ok, view, _html} = live(conn, "/tags/elixir")

    assert has_element?(view, "[data-role='tag-title']", "#elixir")
    assert has_element?(view, "article", "Hello #elixir")
  end

  test "tag pages show an empty state when there are no matching posts", %{conn: conn} do
    assert {:ok, view, _html} = live(conn, "/tags/missing")

    assert has_element?(view, "[data-role='tag-title']", "#missing")
    assert has_element?(view, "div", "No posts yet.")
  end

  test "tag pages do not include direct messages", %{conn: conn, user: user} do
    assert {:ok, _} = Publish.post_note(user, "Secret #elixir", visibility: "direct")

    assert {:ok, view, _html} = live(conn, "/tags/elixir")

    assert has_element?(view, "article", "Hello #elixir")
    refute has_element?(view, "article", "Secret #elixir")
  end

  test "signed-in users can like posts from tag pages", %{conn: conn, user: user, note: note} do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    assert {:ok, view, _html} = live(conn, "/tags/elixir")

    refute Objects.get_by_type_actor_object("Like", user.ap_id, note.ap_id)

    view
    |> element("#post-#{note.id} button[data-role='like']")
    |> render_click()

    assert Objects.get_by_type_actor_object("Like", user.ap_id, note.ap_id)
    assert has_element?(view, "#post-#{note.id} button[data-role='like']", "Unlike")
  end

  test "signed-in users can repost posts from tag pages", %{conn: conn, user: user, note: note} do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    assert {:ok, view, _html} = live(conn, "/tags/elixir")

    refute Objects.get_by_type_actor_object("Announce", user.ap_id, note.ap_id)

    view
    |> element("#post-#{note.id} button[data-role='repost']")
    |> render_click()

    assert Objects.get_by_type_actor_object("Announce", user.ap_id, note.ap_id)
    assert has_element?(view, "#post-#{note.id} button[data-role='repost']", "Unrepost")
  end

  test "signed-in users can react to posts from tag pages", %{conn: conn, user: user, note: note} do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    assert {:ok, view, _html} = live(conn, "/tags/elixir")

    refute Objects.get_emoji_react(user.ap_id, note.ap_id, "🔥")

    view
    |> element("#post-#{note.id} button[data-role='reaction'][data-emoji='🔥']")
    |> render_click()

    assert Objects.get_emoji_react(user.ap_id, note.ap_id, "🔥")

    assert has_element?(
             view,
             "#post-#{note.id} button[data-role='reaction'][data-emoji='🔥']",
             "1"
           )
  end

  test "signed-in users can delete their own posts from tag pages", %{
    conn: conn,
    user: user,
    note: note
  } do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    assert {:ok, view, _html} = live(conn, "/tags/elixir")

    assert has_element?(view, "#post-#{note.id} [data-role='delete-post']")

    view
    |> element("#post-#{note.id} button[data-role='delete-post-confirm']")
    |> render_click()

    assert Objects.get(note.id) == nil
    refute has_element?(view, "#post-#{note.id}")
  end

  test "signed-in users can bookmark posts from tag pages", %{conn: conn, user: user, note: note} do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    assert {:ok, view, _html} = live(conn, "/tags/elixir")

    refute has_element?(view, "#post-#{note.id} button[data-role='bookmark']", "Unbookmark")

    view
    |> element("#post-#{note.id} button[data-role='bookmark']")
    |> render_click()

    assert has_element?(view, "#post-#{note.id} button[data-role='bookmark']", "Unbookmark")
  end

  test "reply modal can be opened from a tag page and replies can be posted", %{
    conn: conn,
    user: user,
    note: note
  } do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    assert {:ok, view, _html} = live(conn, "/tags/elixir")

    refute has_element?(view, "#reply-modal[data-role='reply-modal'][data-state='open']")

    view
    |> element("#post-#{note.id} button[data-role='reply']")
    |> render_click()

    assert has_element?(view, "#reply-modal[data-role='reply-modal'][data-state='open']")

    view
    |> form("#reply-modal-form", reply: %{content: "A reply"})
    |> render_submit()

    [reply] = Objects.list_replies_to(note.ap_id, limit: 1)
    assert reply.data["inReplyTo"] == note.ap_id
  end

  test "reply composer mention autocomplete suggests users", %{conn: conn, user: user, note: note} do
    {:ok, _} = Users.create_local_user("bob")

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    assert {:ok, view, _html} = live(conn, "/tags/elixir")

    view
    |> element("#post-#{note.id} button[data-role='reply']")
    |> render_click()

    _html = render_hook(view, "mention_search", %{"q" => "bo", "scope" => "reply-modal"})
    assert has_element?(view, "[data-role='mention-suggestion']", "@bob")
  end

  test "tag pages can load more posts", %{conn: conn, user: user} do
    for idx <- 1..25 do
      assert {:ok, _} = Publish.post_note(user, "Post #{idx} #elixir")
    end

    notes = Objects.list_notes_by_hashtag("elixir", limit: 40)
    oldest = List.last(notes)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    assert {:ok, view, _html} = live(conn, "/tags/elixir")

    refute has_element?(view, "#post-#{oldest.id}")

    view
    |> element("button[data-role='tag-load-more']")
    |> render_click()

    assert has_element?(view, "#post-#{oldest.id}")
  end
end
