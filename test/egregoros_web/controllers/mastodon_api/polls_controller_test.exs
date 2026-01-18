defmodule EgregorosWeb.MastodonAPI.PollsControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Publish
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint
  alias Egregoros.Workers.RefreshPoll

  describe "GET /api/v1/polls/:id" do
    setup do
      {:ok, alice} = Users.create_local_user("alice")

      question = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
        "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "What's your favorite color?",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{
            "name" => "Red",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 5}
          },
          %{
            "name" => "Blue",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 3}
          }
        ],
        "closed" => "2030-12-31T23:59:59Z"
      }

      {:ok, poll} = Pipeline.ingest(question, local: true)

      %{alice: alice, poll: poll}
    end

    test "returns poll details for unauthenticated user", %{conn: conn, poll: poll} do
      conn = get(conn, "/api/v1/polls/#{poll.id}")

      response = json_response(conn, 200)
      assert response["id"] == Integer.to_string(poll.id)
      assert response["multiple"] == false
      assert response["votes_count"] == 8
      assert response["voters_count"] == 0
      assert length(response["options"]) == 2

      [opt1, opt2] = response["options"]
      assert opt1["title"] == "Red"
      assert opt1["votes_count"] == 5
      assert opt2["title"] == "Blue"
      assert opt2["votes_count"] == 3

      assert response["voted"] == false
      assert response["own_votes"] == []
    end

    test "returns voted=true for user who has voted", %{conn: conn, poll: poll} do
      {:ok, bob} = Users.create_local_user("bob")

      # Bob votes on the poll using Publish.vote_on_poll which properly updates voters
      poll_reloaded = Objects.get_by_ap_id(poll.ap_id)
      {:ok, _} = Publish.vote_on_poll(bob, poll_reloaded, [0])

      # Must authenticate as Bob to get voted=true
      # The auth header triggers FetchOptionalAuth to call Auth.current_user
      Egregoros.Auth.Mock
      |> expect(:current_user, fn _conn -> {:ok, bob} end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer token")
        |> get("/api/v1/polls/#{poll.id}")

      response = json_response(conn, 200)
      assert response["voted"] == true
      assert response["own_votes"] == [0]
    end

    test "returns voted=true even when voters list is missing", %{conn: conn, poll: poll} do
      {:ok, bob} = Users.create_local_user("bob_missing_voters")

      poll_reloaded = Objects.get_by_ap_id(poll.ap_id)
      {:ok, _} = Publish.vote_on_poll(bob, poll_reloaded, [0])

      poll_after_vote = Objects.get_by_ap_id(poll.ap_id)

      {:ok, _} =
        Objects.update_object(poll_after_vote, %{data: Map.delete(poll_after_vote.data, "voters")})

      Egregoros.Auth.Mock
      |> expect(:current_user, fn _conn -> {:ok, bob} end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer token")
        |> get("/api/v1/polls/#{poll.id}")

      response = json_response(conn, 200)
      assert response["voted"] == true
    end

    test "returns 404 for non-existent poll", %{conn: conn} do
      conn = get(conn, "/api/v1/polls/999999")
      assert response(conn, 404) == "Not Found"
    end

    test "returns 404 for non-Question object", %{conn: conn} do
      {:ok, note_alice} = Users.create_local_user("note_alice")
      {:ok, create} = Publish.post_note(note_alice, "This is a note")
      note = Objects.get_by_ap_id(create.object)

      conn = get(conn, "/api/v1/polls/#{note.id}")
      assert response(conn, 404) == "Not Found"
    end

    test "enqueues refresh for remote poll", %{conn: conn} do
      question = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => "https://remote.example/users/alice",
        "context" => "https://remote.example/contexts/" <> Ecto.UUID.generate(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Remote poll",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{
            "name" => "Red",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          },
          %{
            "name" => "Blue",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          }
        ],
        "closed" => "2030-12-31T23:59:59Z"
      }

      {:ok, poll} = Pipeline.ingest(question, local: false)

      conn = get(conn, "/api/v1/polls/#{poll.id}")
      assert response(conn, 200)

      assert_enqueued(
        worker: RefreshPoll,
        queue: "federation_incoming",
        args: %{"ap_id" => poll.ap_id}
      )
    end
  end

  describe "POST /api/v1/polls/:id/votes" do
    setup do
      {:ok, alice} = Users.create_local_user("vote_alice")
      {:ok, bob} = Users.create_local_user("vote_bob")

      question = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
        "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "What's your favorite color?",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{
            "name" => "Red",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          },
          %{
            "name" => "Blue",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          }
        ],
        "closed" => "2030-12-31T23:59:59Z"
      }

      {:ok, poll} = Pipeline.ingest(question, local: true)

      %{alice: alice, bob: bob, poll: poll}
    end

    test "votes on a poll and returns updated poll", %{conn: conn, poll: poll, bob: bob} do
      Egregoros.Auth.Mock
      |> expect(:current_user, fn _conn -> {:ok, bob} end)

      conn = post(conn, "/api/v1/polls/#{poll.id}/votes", %{"choices" => [0]})

      response = json_response(conn, 200)
      assert response["id"] == Integer.to_string(poll.id)
      assert response["voted"] == true

      [opt1, opt2] = response["options"]
      assert opt1["votes_count"] == 1
      assert opt2["votes_count"] == 0
    end

    test "returns 422 when already voted", %{conn: conn, poll: poll, bob: bob} do
      # Bob votes first using Publish.vote_on_poll
      poll_reloaded = Objects.get_by_ap_id(poll.ap_id)
      {:ok, _} = Publish.vote_on_poll(bob, poll_reloaded, [0])

      Egregoros.Auth.Mock
      |> expect(:current_user, fn _conn -> {:ok, bob} end)

      conn = post(conn, "/api/v1/polls/#{poll.id}/votes", %{"choices" => [1]})
      assert json_response(conn, 422)["error"] == "You have already voted on this poll"
    end

    test "returns 422 when voting on own poll", %{conn: conn, poll: poll, alice: alice} do
      Egregoros.Auth.Mock
      |> expect(:current_user, fn _conn -> {:ok, alice} end)

      conn = post(conn, "/api/v1/polls/#{poll.id}/votes", %{"choices" => [0]})
      assert json_response(conn, 422)["error"] == "You cannot vote on your own poll"
    end

    test "returns 422 when poll has expired", %{conn: conn, bob: bob} do
      {:ok, expired_alice} = Users.create_local_user("expired_poll_alice")

      expired_question = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => expired_alice.ap_id,
        "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Expired poll",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{"name" => "Yes", "replies" => %{"totalItems" => 0}},
          %{"name" => "No", "replies" => %{"totalItems" => 0}}
        ],
        "closed" => "2020-01-01T00:00:00Z"
      }

      {:ok, expired_poll} = Pipeline.ingest(expired_question, local: true)

      Egregoros.Auth.Mock
      |> expect(:current_user, fn _conn -> {:ok, bob} end)

      conn = post(conn, "/api/v1/polls/#{expired_poll.id}/votes", %{"choices" => [0]})
      assert json_response(conn, 422)["error"] == "This poll has ended"
    end

    test "returns 422 for invalid choice", %{conn: conn, poll: poll, bob: bob} do
      Egregoros.Auth.Mock
      |> expect(:current_user, fn _conn -> {:ok, bob} end)

      conn = post(conn, "/api/v1/polls/#{poll.id}/votes", %{"choices" => [99]})
      assert json_response(conn, 422)["error"] == "Invalid poll option"
    end

    test "returns 422 for multiple choices on single-choice poll", %{
      conn: conn,
      poll: poll,
      bob: bob
    } do
      Egregoros.Auth.Mock
      |> expect(:current_user, fn _conn -> {:ok, bob} end)

      conn = post(conn, "/api/v1/polls/#{poll.id}/votes", %{"choices" => [0, 1]})
      assert json_response(conn, 422)["error"] == "This poll only allows a single choice"
    end

    test "returns 422 for non-list choices param", %{conn: conn, poll: poll, bob: bob} do
      Egregoros.Auth.Mock
      |> expect(:current_user, fn _conn -> {:ok, bob} end)

      conn = post(conn, "/api/v1/polls/#{poll.id}/votes", %{"choices" => "0"})
      assert json_response(conn, 422)["error"] == "Invalid poll option"
    end

    test "returns 422 for missing choices param", %{conn: conn, poll: poll, bob: bob} do
      Egregoros.Auth.Mock
      |> expect(:current_user, fn _conn -> {:ok, bob} end)

      conn = post(conn, "/api/v1/polls/#{poll.id}/votes", %{})
      assert json_response(conn, 422)["error"] == "Missing required parameter: choices"
    end

    test "returns 404 for non-existent poll", %{conn: conn, bob: bob} do
      Egregoros.Auth.Mock
      |> expect(:current_user, fn _conn -> {:ok, bob} end)

      conn = post(conn, "/api/v1/polls/999999/votes", %{"choices" => [0]})
      assert response(conn, 404) == "Not Found"
    end
  end

  describe "POST /api/v1/polls/:id/votes with multiple choice (anyOf)" do
    setup do
      {:ok, alice} = Users.create_local_user("anyof_poll_alice")
      {:ok, bob} = Users.create_local_user("anyof_poll_bob")

      question = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
        "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Select all that apply",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "anyOf" => [
          %{
            "name" => "Option A",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          },
          %{
            "name" => "Option B",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          },
          %{
            "name" => "Option C",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          }
        ],
        "closed" => "2030-12-31T23:59:59Z"
      }

      {:ok, poll} = Pipeline.ingest(question, local: true)

      %{alice: alice, bob: bob, poll: poll}
    end

    test "allows multiple choices on anyOf poll", %{conn: conn, poll: poll, bob: bob} do
      Egregoros.Auth.Mock
      |> expect(:current_user, fn _conn -> {:ok, bob} end)

      conn = post(conn, "/api/v1/polls/#{poll.id}/votes", %{"choices" => [0, 2]})

      response = json_response(conn, 200)
      assert response["multiple"] == true
      assert response["voted"] == true

      [opt_a, opt_b, opt_c] = response["options"]
      assert opt_a["votes_count"] == 1
      assert opt_b["votes_count"] == 0
      assert opt_c["votes_count"] == 1
    end
  end
end
