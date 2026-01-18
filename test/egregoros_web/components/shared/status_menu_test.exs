defmodule EgregorosWeb.Components.Shared.StatusMenuTest do
  use EgregorosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Egregoros.Users
  alias EgregorosWeb.Components.Shared.StatusMenu
  alias EgregorosWeb.Endpoint

  test "shows delete action for local Question posts owned by the current user" do
    {:ok, user} = Users.create_local_user("status_menu_poll_owner")

    entry = %{
      object: %{
        id: 1,
        type: "Question",
        local: true,
        actor: user.ap_id,
        ap_id: Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        data: %{}
      },
      actor: %{
        display_name: user.nickname,
        nickname: user.nickname,
        handle: "@#{user.nickname}",
        avatar_url: nil
      },
      attachments: [],
      liked?: false,
      likes_count: 0,
      reposted?: false,
      reposts_count: 0,
      bookmarked?: false,
      reactions: %{}
    }

    html =
      render_component(&StatusMenu.status_menu/1, %{
        card_id: "post-1",
        entry: entry,
        current_user: user
      })

    assert html =~ ~s(data-role="delete-post")
  end
end
