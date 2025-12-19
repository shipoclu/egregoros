defmodule PleromaReduxWeb.TimelineLiveTest do
  use PleromaReduxWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PleromaRedux.Timeline

  setup do
    Timeline.reset()
    :ok
  end

  test "posting updates the timeline without refresh", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    refute has_element?(view, "article", "Hello world")

    view
    |> form("form", content: "Hello world")
    |> render_submit()

    assert has_element?(view, "article", "Hello world")
  end
end
