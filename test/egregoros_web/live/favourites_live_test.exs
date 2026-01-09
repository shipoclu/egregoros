defmodule EgregorosWeb.FavouritesLiveTest do
  use EgregorosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Egregoros.Activities.Note
  alias Egregoros.Interactions
  alias Egregoros.Pipeline
  alias Egregoros.Users

  setup do
    {:ok, user} = Users.create_local_user("alice")
    %{user: user}
  end

  test "favourites page shows liked posts and allows unliking", %{conn: conn, user: user} do
    {:ok, note} = Pipeline.ingest(Note.build(user, "Hello favourited"), local: true)
    assert {:ok, _} = Interactions.toggle_like(user, note.id)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, "/favourites")

    assert has_element?(view, "#post-#{note.id}", "Hello favourited")

    view
    |> element("#post-#{note.id} button[data-role='like']")
    |> render_click()

    refute has_element?(view, "#post-#{note.id}")
  end
end
