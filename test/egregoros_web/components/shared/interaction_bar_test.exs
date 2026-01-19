defmodule EgregorosWeb.Components.Shared.InteractionBarTest do
  use EgregorosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EgregorosWeb.Components.Shared.InteractionBar
  alias EgregorosWeb.Endpoint

  test "reaction bar falls back to default reactions when reactions are missing" do
    html =
      render_component(&InteractionBar.interaction_bar/1, %{
        id: "post-1",
        current_user: %{id: 1},
        entry: %{
          object: %{
            id: 1,
            ap_id: Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
            type: "Note",
            local: true,
            data: %{"content" => "Hello"}
          },
          actor: %{handle: "@alice", nickname: "alice", display_name: "Alice", avatar_url: nil},
          liked?: false,
          likes_count: 0,
          reposted?: false,
          reposts_count: 0,
          reactions: nil
        }
      })

    assert html =~ "🔥"
    assert html =~ "👍"
    assert html =~ "❤️"
  end

  test "reaction picker uses feed id from string object id when present" do
    html =
      render_component(&InteractionBar.interaction_bar/1, %{
        id: "post-1",
        current_user: %{id: 1},
        entry: %{
          object: %{
            "id" => 123,
            id: nil,
            ap_id: Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
            type: "Note",
            local: true,
            data: %{"content" => "Hello"}
          },
          actor: %{handle: "@alice", nickname: "alice", display_name: "Alice", avatar_url: nil},
          liked?: false,
          likes_count: 0,
          reposted?: false,
          reposts_count: 0,
          reactions: %{}
        }
      })

    assert html =~ ~s(data-feed-id="123")
  end

  test "reaction picker omits feed id when no entry id exists" do
    html =
      render_component(&InteractionBar.interaction_bar/1, %{
        id: "post-1",
        current_user: %{id: 1},
        entry: %{
          object: %{
            id: nil,
            ap_id: Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
            type: "Note",
            local: true,
            data: %{"content" => "Hello"}
          },
          actor: %{handle: "@alice", nickname: "alice", display_name: "Alice", avatar_url: nil},
          liked?: false,
          likes_count: 0,
          reposted?: false,
          reposts_count: 0,
          reactions: %{}
        }
      })

    refute html =~ ~s(data-feed-id=)
  end
end
