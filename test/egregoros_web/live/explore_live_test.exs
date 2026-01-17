defmodule EgregorosWeb.ExploreLiveTest do
  use EgregorosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Egregoros.Publish
  alias Egregoros.Relationships
  alias Egregoros.Users

  test "explore shows trending tags for guests", %{conn: conn} do
    {:ok, user} = Users.create_local_user("alice")
    assert {:ok, _} = Publish.post_note(user, "Hello #elixir")

    {:ok, view, _html} = live(conn, "/explore")

    assert has_element?(view, "[data-role='nav-explore'] .hero-map")
    assert has_element?(view, "[data-role='explore-trending-tags']")
    assert has_element?(view, "[data-role='explore-trending-tag'][href='/tags/elixir']")
  end

  test "explore shows suggestions and followed tags for signed-in users", %{conn: conn} do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    assert {:ok, _} = Publish.post_note(bob, "Hello from bob")

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "FollowTag",
               actor: alice.ap_id,
               object: "#elixir",
               activity_ap_id: nil
             })

    conn = Plug.Test.init_test_session(conn, %{user_id: alice.id})
    {:ok, view, _html} = live(conn, "/explore")

    assert has_element?(view, "[data-role='explore-followed-tags']")
    assert has_element?(view, "[data-role='explore-followed-tag'][href='/tags/elixir']")

    assert has_element?(view, "[data-role='explore-suggestions']")
    assert has_element?(view, "[data-role='explore-suggestion-handle']", "@bob")
  end
end
