defmodule EgregorosWeb.MastodonAPI.PollRendererTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Object
  alias Egregoros.Pipeline
  alias Egregoros.Publish
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.MastodonAPI.PollRenderer
  alias EgregorosWeb.Endpoint

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  describe "render/2" do
    test "returns nil for non-Question objects" do
      object = %Object{id: "1", type: "Note", data: %{}}
      assert PollRenderer.render(object, nil) == nil
    end

    test "renders an empty poll when oneOf/anyOf are missing" do
      object = %Object{
        id: "1",
        type: "Question",
        actor: "https://example.com/users/alice",
        data: %{}
      }

      rendered = PollRenderer.render(object, nil)

      assert %{
               "id" => "1",
               "expires_at" => nil,
               "expired" => false,
               "multiple" => false,
               "votes_count" => 0,
               "voters_count" => 0,
               "options" => [],
               "emojis" => []
             } = rendered

      refute Map.has_key?(rendered, "voted")
      refute Map.has_key?(rendered, "own_votes")
    end

    test "renders a poll with options and counts" do
      {:ok, alice} = Users.create_local_user("poll_render_alice")

      question = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
        "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
        "to" => [@as_public],
        "content" => "Is Tenshi eating a corndog cute?",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{
            "name" => "Absolutely!",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          },
          %{
            "name" => "Sure",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          }
        ],
        "closed" => "2030-12-31T23:59:59Z"
      }

      {:ok, poll} = Pipeline.ingest(question, local: true)

      rendered = PollRenderer.render(poll, nil)

      assert rendered["id"] == poll.id
      assert rendered["multiple"] == false
      assert rendered["votes_count"] == 0
      assert rendered["voters_count"] == 0
      assert rendered["expired"] == false
      assert is_binary(rendered["expires_at"])

      [opt1, opt2] = rendered["options"]
      assert opt1 == %{"title" => "Absolutely!", "votes_count" => 0}
      assert opt2 == %{"title" => "Sure", "votes_count" => 0}

      refute Map.has_key?(rendered, "voted")
      refute Map.has_key?(rendered, "own_votes")
    end

    test "uses votersCount from ActivityPub data for remote polls" do
      object = %Object{
        id: "1",
        type: "Question",
        actor: "https://example.com/users/alice",
        local: false,
        data: %{
          "oneOf" => [
            %{"name" => "a", "replies" => %{"type" => "Collection", "totalItems" => 0}}
          ],
          "votersCount" => 10
        }
      }

      rendered = PollRenderer.render(object, nil)
      assert rendered["voters_count"] == 10
    end

    test "detects multiple choice and own_votes" do
      {:ok, alice} = Users.create_local_user("poll_render_multi_alice")
      {:ok, bob} = Users.create_local_user("poll_render_multi_bob")

      question = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
        "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
        "to" => [@as_public],
        "content" => "Which input devices do you use?",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "anyOf" => [
          %{
            "name" => "Mouse",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          },
          %{
            "name" => "Trackball",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          }
        ],
        "closed" => "2030-12-31T23:59:59Z"
      }

      {:ok, poll} = Pipeline.ingest(question, local: true)
      {:ok, _updated} = Publish.vote_on_poll(bob, poll, [0, 1])

      poll = Egregoros.Objects.get_by_ap_id(poll.ap_id)

      rendered = PollRenderer.render(poll, bob)

      assert rendered["multiple"] == true
      assert rendered["votes_count"] == 2
      assert rendered["voters_count"] == 1
      assert rendered["voted"] == true
      assert rendered["own_votes"] == [0, 1]

      [opt1, opt2] = rendered["options"]
      assert opt1 == %{"title" => "Mouse", "votes_count" => 1}
      assert opt2 == %{"title" => "Trackball", "votes_count" => 1}
    end

    test "does not crash on polls with no end date" do
      {:ok, alice} = Users.create_local_user("poll_render_no_end_alice")

      question = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
        "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
        "to" => [@as_public],
        "content" => "Endless poll",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{
            "name" => "Yes",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          },
          %{
            "name" => "No",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          }
        ]
      }

      {:ok, poll} = Pipeline.ingest(question, local: true)

      rendered = PollRenderer.render(poll, nil)

      assert rendered["expires_at"] == nil
      assert rendered["expired"] == false

      refute Map.has_key?(rendered, "voted")
      refute Map.has_key?(rendered, "own_votes")
    end

    test "does not strip HTML tags from option titles" do
      {:ok, alice} = Users.create_local_user("poll_render_html_alice")

      question = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
        "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
        "to" => [@as_public],
        "content" => "HTML options",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{
            "name" => "<input type=\"date\">",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          },
          %{
            "name" => "<input type=\"date\" />",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          }
        ],
        "closed" => "2030-12-31T23:59:59Z"
      }

      {:ok, poll} = Pipeline.ingest(question, local: true)

      rendered = PollRenderer.render(poll, nil)

      [opt1, opt2] = rendered["options"]
      assert opt1 == %{"title" => "<input type=\"date\">", "votes_count" => 0}
      assert opt2 == %{"title" => "<input type=\"date\" />", "votes_count" => 0}

      refute Map.has_key?(rendered, "voted")
      refute Map.has_key?(rendered, "own_votes")
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
          "endTime" => DateTime.to_iso8601(expires_at)
        }
      }

      rendered = PollRenderer.render(object, %User{ap_id: "https://example.com/users/bob"})

      assert rendered["expires_at"] == DateTime.to_iso8601(expires_at)

      assert rendered["options"] == [
               %{"title" => "a", "votes_count" => 0},
               %{"title" => "", "votes_count" => 0}
             ]

      assert rendered["votes_count"] == 0
      assert rendered["voters_count"] == 0
      assert rendered["voted"] == false
    end

    test "poll owner does not have own_votes and invalid closed dates are ignored" do
      object = %Object{
        id: 1,
        type: "Question",
        actor: "https://example.com/users/alice",
        internal: %{"poll" => %{"voters" => ["https://example.com/users/alice"]}},
        data: %{
          "anyOf" => [%{"name" => "a", "replies" => %{"totalItems" => 1}}],
          "closed" => "not-a-date"
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
end
