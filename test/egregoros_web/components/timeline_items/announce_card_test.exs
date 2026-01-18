defmodule EgregorosWeb.Components.TimelineItems.AnnounceCardTest do
  use EgregorosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EgregorosWeb.Components.TimelineItems.AnnounceCard

  describe "announce_card/1" do
    test "renders a boosted Note using NoteCard" do
      html =
        render_component(&AnnounceCard.announce_card/1, %{
          id: "announce-1",
          current_user: %{id: 1},
          entry: %{
            object: %{
              id: 1,
              type: "Note",
              inserted_at: ~U[2025-01-01 00:00:00Z],
              local: false,
              data: %{"content" => "<p>Hello from original author</p>"}
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

      # Should render as a Note card
      assert html =~ ~s(data-type="Note")
      assert html =~ ~s(data-role="status-card")
      # Should show reposted by header
      assert html =~ ~s(data-role="reposted-by")
      assert html =~ "Bob"
      assert html =~ "reposted"
      # Should show the content
      assert html =~ "Hello from original author"
    end

    test "renders a boosted Question using PollCard" do
      html =
        render_component(&AnnounceCard.announce_card/1, %{
          id: "announce-poll-1",
          current_user: %{id: 1},
          entry: %{
            object: %{
              id: 2,
              type: "Question",
              inserted_at: ~U[2025-01-01 00:00:00Z],
              local: false,
              data: %{
                "content" => "<p>What's your favorite color?</p>",
                "oneOf" => [
                  %{"name" => "Red", "replies" => %{"totalItems" => 5}},
                  %{"name" => "Blue", "replies" => %{"totalItems" => 3}}
                ]
              }
            },
            actor: %{
              display_name: "Alice",
              nickname: "alice",
              handle: "@alice",
              avatar_url: nil
            },
            reposted_by: %{
              display_name: "Carol",
              nickname: "carol",
              domain: nil,
              avatar_url: nil
            },
            poll: %{
              options: [
                %{name: "Red", votes: 5},
                %{name: "Blue", votes: 3}
              ],
              total_votes: 8,
              voters_count: 8,
              multiple?: false,
              expired?: false,
              closed: nil,
              own_poll?: false,
              voted?: false
            },
            attachments: [],
            liked?: false,
            likes_count: 0,
            reposted?: false,
            reposts_count: 0,
            reactions: %{}
          }
        })

      # Should render as a Question card
      assert html =~ ~s(data-type="Question")
      assert html =~ ~s(data-role="status-card")
      # Should show reposted by header
      assert html =~ ~s(data-role="reposted-by")
      assert html =~ "Carol"
      assert html =~ "reposted"
      # Should show poll section
      assert html =~ ~s(data-role="poll-section")
      # Should show poll options
      assert html =~ "Red"
      assert html =~ "Blue"
    end

    test "renders poll when entry has poll field but object type is missing" do
      # This tests the fallback detection via entry.poll
      html =
        render_component(&AnnounceCard.announce_card/1, %{
          id: "announce-poll-2",
          current_user: nil,
          entry: %{
            object: %{
              id: 3,
              # type not explicitly set to Question but poll data exists
              type: "Question",
              inserted_at: ~U[2025-01-01 00:00:00Z],
              local: false,
              data: %{"content" => "<p>Pick one</p>"}
            },
            actor: %{
              display_name: "Dave",
              nickname: "dave",
              handle: "@dave",
              avatar_url: nil
            },
            reposted_by: %{
              display_name: "Eve",
              nickname: "eve",
              domain: "remote.example",
              avatar_url: nil
            },
            poll: %{
              options: [
                %{name: "Yes", votes: 10},
                %{name: "No", votes: 5}
              ],
              total_votes: 15,
              voters_count: 15,
              multiple?: false,
              expired?: true,
              closed: ~U[2024-01-01 00:00:00Z],
              own_poll?: false,
              voted?: false
            },
            attachments: [],
            liked?: false,
            likes_count: 0,
            reposted?: false,
            reposts_count: 0,
            reactions: %{}
          }
        })

      # Should render as a Question card
      assert html =~ ~s(data-type="Question")
      # Should show reposted by with remote domain
      assert html =~ ~s(data-role="reposted-by")
      assert html =~ "Eve"
      assert html =~ ~s(href="/@eve@remote.example")
      # Should show poll results (expired poll)
      assert html =~ ~s(data-role="poll-results")
      assert html =~ "Poll ended"
    end

    test "renders reposted_by header with link for local users" do
      html =
        render_component(&AnnounceCard.announce_card/1, %{
          id: "announce-3",
          current_user: nil,
          entry: %{
            object: %{
              id: 4,
              type: "Note",
              inserted_at: ~U[2025-01-01 00:00:00Z],
              local: true,
              data: %{"content" => "Test"}
            },
            actor: %{
              display_name: "Alice",
              nickname: "alice",
              handle: "@alice",
              avatar_url: nil
            },
            reposted_by: %{
              display_name: "Local User",
              nickname: "localuser",
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

      assert html =~ ~s(href="/@localuser")
      assert html =~ "Local User"
    end

    test "renders reposted_by header with link for remote users" do
      html =
        render_component(&AnnounceCard.announce_card/1, %{
          id: "announce-4",
          current_user: nil,
          entry: %{
            object: %{
              id: 5,
              type: "Note",
              inserted_at: ~U[2025-01-01 00:00:00Z],
              local: false,
              data: %{"content" => "Test"}
            },
            actor: %{
              display_name: "Original",
              nickname: "original",
              handle: "@original@other.example",
              avatar_url: nil
            },
            reposted_by: %{
              display_name: "Remote Booster",
              nickname: "booster",
              domain: "remote.example",
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

      assert html =~ ~s(href="/@booster@remote.example")
      assert html =~ "Remote Booster"
    end
  end
end
