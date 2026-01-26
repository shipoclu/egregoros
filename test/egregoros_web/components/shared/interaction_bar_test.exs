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
            "id" => "123",
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

  test "reply button prefill mention handles add host from tag id and atom keys" do
    html =
      render_component(&InteractionBar.interaction_bar/1, %{
        id: "post-1",
        current_user: %{id: 1},
        reply_mode: :modal,
        entry: %{
          object: %{
            id: 1,
            ap_id: "https://remote.example/objects/1",
            type: "Note",
            local: false,
            data: %{
              tag: [
                %{
                  type: "Mention",
                  id: "https://remote.example/users/bob",
                  name: "@bob"
                }
              ]
            }
          },
          actor: %{handle: "@alice", nickname: "alice", display_name: "Alice", avatar_url: nil},
          liked?: false,
          likes_count: 0,
          reposted?: false,
          reposts_count: 0,
          reactions: %{}
        }
      })

    assert html =~ "egregoros:reply-open"
    assert html =~ "@bob@remote.example"
  end

  test "reply button prefill mention handles omit local domains" do
    html =
      render_component(&InteractionBar.interaction_bar/1, %{
        id: "post-1",
        current_user: %{id: 1},
        reply_mode: :modal,
        entry: %{
          object: %{
            id: 1,
            ap_id: Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
            type: "Note",
            local: true,
            data: %{
              "tag" => [
                %{
                  "type" => "Mention",
                  "href" => Endpoint.url() <> "/users/bob",
                  "name" => "@bob@localhost"
                }
              ]
            }
          },
          actor: %{handle: "@alice", nickname: "alice", display_name: "Alice", avatar_url: nil},
          liked?: false,
          likes_count: 0,
          reposted?: false,
          reposts_count: 0,
          reactions: %{}
        }
      })

    assert html =~ "@bob"
    refute html =~ "@bob@localhost"
  end
end
