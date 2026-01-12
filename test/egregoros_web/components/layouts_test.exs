defmodule EgregorosWeb.LayoutsTest do
  use EgregorosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EgregorosWeb.Layouts

  defp slot_text(text) when is_binary(text) do
    [%{inner_block: fn _, _ -> text end}]
  end

  test "renders a user menu when signed in" do
    html =
      render_component(&Layouts.app/1, %{
        flash: %{},
        current_user: %{
          nickname: "alice",
          name: "Alice Example",
          avatar_url: "/uploads/avatar.png"
        },
        current_scope: nil,
        inner_block: slot_text("Main content")
      })

    assert html =~ ~s(data-role="user-menu")
    assert html =~ ~s(phx-click-away=)
    assert html =~ ~s(phx-window-keydown=)
    assert html =~ ~s(phx-key="escape")
    assert html =~ ~s(href="/@alice")
    assert html =~ ~s(href="/settings")
    assert html =~ ~s(action="/logout")
    refute html =~ "&middot;"
  end

  test "renders an admin entry for admin users" do
    html =
      render_component(&Layouts.app/1, %{
        flash: %{},
        current_user: %{nickname: "alice", admin: true},
        current_scope: nil,
        inner_block: slot_text("Main content")
      })

    assert html =~ ~s(data-role="user-menu-admin")
    assert html =~ ~s(href="/admin")
  end

  test "renders login/register links when signed out" do
    html =
      render_component(&Layouts.app/1, %{
        flash: %{},
        current_user: nil,
        current_scope: nil,
        inner_block: slot_text("Main content")
      })

    refute html =~ ~s(data-role="user-menu")
    assert html =~ ~s(href="/login")
    assert html =~ ~s(href="/register")
  end
end
