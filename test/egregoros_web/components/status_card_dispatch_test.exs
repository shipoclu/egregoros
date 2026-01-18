defmodule EgregorosWeb.StatusCardDispatchTest do
  use EgregorosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EgregorosWeb.StatusCard

  test "dispatches decorated repost entries through the Announce branch" do
    html =
      render_component(&StatusCard.status_card/1, %{
        id: "post-1",
        current_user: %{id: 1},
        entry: %{
          object: %{
            id: 1,
            type: "Mystery",
            inserted_at: ~U[2025-01-01 00:00:00Z],
            local: false,
            data: %{"content" => "<p>Hello</p>"}
          },
          actor: %{
            display_name: "Alice",
            nickname: "alice",
            handle: "@alice",
            avatar_url: nil
          },
          reposted_by: %{
            display_name: "Bob",
            nickname: "bob",
            domain: nil,
            avatar_url: nil
          },
          attachments: [],
          liked?: false,
          likes_count: 0,
          reposted?: false,
          reposts_count: 0,
          reactions: %{}
        }
      })

    assert html =~ ~s(data-role="status-card")
    assert html =~ ~s(data-type="Note")
    refute html =~ ~s(data-type="unknown")
    refute html =~ "Unsupported content type"
  end
end
