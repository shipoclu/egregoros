defmodule EgregorosWeb.MastodonAPI.PollRendererTest do
  use ExUnit.Case, async: true

  alias Egregoros.Object
  alias Egregoros.User
  alias EgregorosWeb.MastodonAPI.PollRenderer

  test "returns nil for non-Question objects" do
    object = %Object{id: 1, type: "Note", data: %{}}
    assert PollRenderer.render(object, nil) == nil
  end

  test "renders an empty poll when oneOf/anyOf are missing" do
    object = %Object{id: 1, type: "Question", actor: "https://example.com/users/alice", data: %{}}

    assert %{
             "id" => "1",
             "expires_at" => nil,
             "expired" => false,
             "multiple" => false,
             "votes_count" => 0,
             "voters_count" => 0,
             "options" => [],
             "emojis" => [],
             "voted" => false,
             "own_votes" => []
           } = PollRenderer.render(object, nil)
  end

  test "handles non-map options and non-integer vote counts" do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(3600, :second)
      |> DateTime.truncate(:second)

    object = %Object{
      id: 1,
      type: "Question",
      actor: "https://example.com/users/alice",
      data: %{
        "oneOf" => [
          %{"name" => "a", "replies" => %{"totalItems" => "5"}},
          "oops"
        ],
        "endTime" => DateTime.to_iso8601(expires_at),
        "voters" => "not-a-list"
      }
    }

    rendered = PollRenderer.render(object, %User{ap_id: "https://example.com/users/bob"})

    assert rendered["expires_at"] == DateTime.to_iso8601(expires_at)

    assert rendered["options"] == [
             %{"title" => "a", "votes_count" => 0, "index" => 0},
             %{"title" => "", "votes_count" => 0, "index" => 1}
           ]

    assert rendered["votes_count"] == 0
    assert rendered["voted"] == false
  end

  test "poll owner does not have own_votes and invalid closed dates are ignored" do
    object = %Object{
      id: 1,
      type: "Question",
      actor: "https://example.com/users/alice",
      data: %{
        "anyOf" => [%{"name" => "a", "replies" => %{"totalItems" => 1}}],
        "closed" => "not-a-date",
        "voters" => ["https://example.com/users/alice"]
      }
    }

    rendered = PollRenderer.render(object, %User{ap_id: "https://example.com/users/alice"})

    assert rendered["multiple"] == true
    assert rendered["expires_at"] == nil
    assert rendered["own_votes"] == []
    assert rendered["voted"] == true
    assert rendered["voters_count"] == 1
    assert rendered["votes_count"] == 1
  end
end
