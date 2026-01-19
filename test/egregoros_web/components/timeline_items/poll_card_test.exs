defmodule EgregorosWeb.Components.TimelineItems.PollCardTest do
  use EgregorosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EgregorosWeb.Components.TimelineItems.PollCard

  test "renders radio inputs for single-choice polls when the user can vote" do
    poll = %{
      multiple?: false,
      own_poll?: false,
      voted?: false,
      expired?: false,
      options: [
        %{name: "Option A", votes: 0},
        %{name: "Option B", votes: 0}
      ],
      total_votes: 0,
      voters_count: 0,
      closed: nil
    }

    entry = %{
      object: %{
        id: 123,
        type: "Question",
        ap_id: EgregorosWeb.Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        inserted_at: ~U[2025-01-01 00:00:00Z],
        local: true,
        data: %{"content" => "Poll content"}
      },
      actor: %{
        display_name: "Alice",
        nickname: "alice",
        handle: "@alice",
        avatar_url: nil
      },
      poll: poll,
      attachments: [],
      liked?: false,
      likes_count: 0,
      reposted?: false,
      reposts_count: 0,
      bookmarked?: false,
      reactions: %{}
    }

    html =
      render_component(&PollCard.poll_card/1, %{
        id: "post-1",
        entry: entry,
        current_user: %{id: 1},
        back_timeline: nil,
        reply_mode: :navigate
      })

    assert html =~ ~s(id="poll-form-post-1")
    assert html =~ ~s(name="choices[]")
    assert html =~ ~s(type="radio")
    refute html =~ ~s(type="checkbox")
    refute html =~ ~s(data-role="poll-results")
  end

  test "renders checkbox inputs for multiple-choice polls when the user can vote" do
    poll = %{
      multiple?: true,
      own_poll?: false,
      voted?: false,
      expired?: false,
      options: [
        %{name: "Option A", votes: 0},
        %{name: "Option B", votes: 0}
      ],
      total_votes: 0,
      voters_count: 0,
      closed: nil
    }

    entry = %{
      object: %{
        id: 123,
        type: "Question",
        ap_id: EgregorosWeb.Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        inserted_at: ~U[2025-01-01 00:00:00Z],
        local: true,
        data: %{"content" => "Poll content"}
      },
      actor: %{
        display_name: "Alice",
        nickname: "alice",
        handle: "@alice",
        avatar_url: nil
      },
      poll: poll,
      attachments: [],
      liked?: false,
      likes_count: 0,
      reposted?: false,
      reposts_count: 0,
      bookmarked?: false,
      reactions: %{}
    }

    html =
      render_component(&PollCard.poll_card/1, %{
        id: "post-1",
        entry: entry,
        current_user: %{id: 1},
        back_timeline: nil,
        reply_mode: :navigate
      })

    assert html =~ ~s(id="poll-form-post-1")
    assert html =~ ~s(name="choices[]")
    assert html =~ ~s(type="checkbox")
    refute html =~ ~s(type="radio")
    refute html =~ ~s(data-role="poll-results")
  end

  test "renders poll results instead of a form when the user cannot vote" do
    poll = %{
      multiple?: false,
      own_poll?: false,
      voted?: true,
      expired?: false,
      options: [
        %{name: "Option A", votes: 2},
        %{name: "Option B", votes: 1}
      ],
      total_votes: 3,
      voters_count: 3,
      closed: nil
    }

    entry = %{
      object: %{
        id: 123,
        type: "Question",
        ap_id: EgregorosWeb.Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        inserted_at: ~U[2025-01-01 00:00:00Z],
        local: true,
        data: %{"content" => "Poll content"}
      },
      actor: %{
        display_name: "Alice",
        nickname: "alice",
        handle: "@alice",
        avatar_url: nil
      },
      poll: poll,
      attachments: [],
      liked?: false,
      likes_count: 0,
      reposted?: false,
      reposts_count: 0,
      bookmarked?: false,
      reactions: %{}
    }

    html =
      render_component(&PollCard.poll_card/1, %{
        id: "post-1",
        entry: entry,
        current_user: %{id: 1},
        back_timeline: nil,
        reply_mode: :navigate
      })

    assert html =~ ~s(data-role="poll-results")
    refute html =~ ~s(id="poll-form-post-1")
  end
end
