defmodule Egregoros.PublishVoteOnPollTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Publish
  alias Egregoros.Users
  alias Egregoros.Workers.DeliverActivity
  alias EgregorosWeb.Endpoint
  alias EgregorosWeb.Endpoint

  describe "vote_on_poll/3" do
    setup do
      {:ok, alice} = Users.create_local_user("alice")
      {:ok, bob} = Users.create_local_user("bob")
      {:ok, carol} = Users.create_local_user("carol")

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
          },
          %{
            "name" => "Green",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          }
        ],
        "closed" => "2030-12-31T23:59:59Z"
      }

      {:ok, poll} = Pipeline.ingest(question, local: true)

      %{alice: alice, bob: bob, carol: carol, poll: poll}
    end

    test "allows a user to vote on a single-choice poll", %{poll: poll, bob: bob} do
      assert {:ok, updated_poll} = Publish.vote_on_poll(bob, poll, [0])

      red_option = Enum.find(updated_poll.data["oneOf"], &(&1["name"] == "Red"))
      assert red_option["replies"]["totalItems"] == 1
      assert bob.ap_id in get_in(updated_poll.internal, ["poll", "voters"])
    end

    test "rejects voting on own poll", %{poll: poll, alice: alice} do
      assert {:error, :own_poll} = Publish.vote_on_poll(alice, poll, [0])
    end

    test "rejects voting twice on the same poll", %{poll: poll, bob: bob} do
      assert {:ok, _} = Publish.vote_on_poll(bob, poll, [0])

      # Reload the poll
      updated_poll = Objects.get_by_ap_id(poll.ap_id)

      assert {:error, :already_voted} = Publish.vote_on_poll(bob, updated_poll, [1])
    end

    test "rejects voting twice even when internal poll voter state is missing", %{
      poll: poll,
      bob: bob
    } do
      assert {:ok, _} = Publish.vote_on_poll(bob, poll, [0])

      updated_poll = Objects.get_by_ap_id(poll.ap_id)

      {:ok, updated_poll} =
        Objects.update_object(updated_poll, %{internal: %{}})

      assert {:error, :already_voted} = Publish.vote_on_poll(bob, updated_poll, [1])
    end

    test "rejects multiple choices on single-choice poll", %{poll: poll, bob: bob} do
      assert {:error, :multiple_choices_not_allowed} = Publish.vote_on_poll(bob, poll, [0, 1])
    end

    test "rejects invalid choice index", %{poll: poll, bob: bob} do
      # There are only 3 options (0, 1, 2)
      assert {:error, :invalid_choice} = Publish.vote_on_poll(bob, poll, [99])
    end

    test "rejects negative choice index", %{poll: poll, bob: bob} do
      assert {:error, :invalid_choice} = Publish.vote_on_poll(bob, poll, [-1])
    end

    test "rejects empty choices", %{poll: poll, bob: bob} do
      assert {:error, :invalid_choice} = Publish.vote_on_poll(bob, poll, [])
    end

    test "rejects voting on expired poll", %{alice: alice, bob: bob} do
      expired_question = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
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

      assert {:error, :poll_expired} = Publish.vote_on_poll(bob, expired_poll, [0])
    end

    test "federates votes to the remote poll actor", %{bob: bob} do
      {:ok, remote_actor} =
        Users.create_user(%{
          nickname: "remote",
          ap_id: "https://remote.example/users/remote",
          inbox: "https://remote.example/users/remote/inbox",
          outbox: "https://remote.example/users/remote/outbox",
          public_key: "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----\n",
          local: false
        })

      question = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => remote_actor.ap_id,
        "context" => "https://remote.example/contexts/" <> Ecto.UUID.generate(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Remote poll",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{
            "name" => "Option A",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          },
          %{
            "name" => "Option B",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          }
        ],
        "closed" => "2030-12-31T23:59:59Z"
      }

      {:ok, poll} = Pipeline.ingest(question, local: false)

      assert {:ok, _updated_poll} = Publish.vote_on_poll(bob, poll, [1])

      assert_enqueued(
        worker: DeliverActivity,
        queue: "federation_outgoing",
        args: %{
          "user_id" => bob.id,
          "inbox_url" => remote_actor.inbox,
          "activity" => %{
            "type" => "Create",
            "object" => %{"type" => "Answer"}
          }
        }
      )
    end
  end

  describe "vote_on_poll/3 with multiple choice (anyOf)" do
    setup do
      {:ok, alice} = Users.create_local_user("multi_alice")
      {:ok, bob} = Users.create_local_user("multi_bob")

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

    test "allows multiple choices on anyOf poll", %{poll: poll, bob: bob} do
      assert {:ok, updated_poll} = Publish.vote_on_poll(bob, poll, [0, 2])

      opt_a = Enum.find(updated_poll.data["anyOf"], &(&1["name"] == "Option A"))
      opt_b = Enum.find(updated_poll.data["anyOf"], &(&1["name"] == "Option B"))
      opt_c = Enum.find(updated_poll.data["anyOf"], &(&1["name"] == "Option C"))

      assert opt_a["replies"]["totalItems"] == 1
      assert opt_b["replies"]["totalItems"] == 0
      assert opt_c["replies"]["totalItems"] == 1

      assert bob.ap_id in get_in(updated_poll.internal, ["poll", "voters"])
    end

    test "allows single choice on anyOf poll", %{poll: poll, bob: bob} do
      assert {:ok, updated_poll} = Publish.vote_on_poll(bob, poll, [1])

      opt_b = Enum.find(updated_poll.data["anyOf"], &(&1["name"] == "Option B"))
      assert opt_b["replies"]["totalItems"] == 1
    end
  end

  describe "vote_on_poll/3 with remote poll delivery" do
    test "enqueues delivery when voting on a remote poll" do
      {:ok, voter} = Users.create_local_user("remote_poll_voter")

      {:ok, poll_creator} =
        Users.create_user(%{
          nickname: "pollcreator",
          ap_id: "https://remote.example/users/pollcreator",
          inbox: "https://remote.example/users/pollcreator/inbox",
          outbox: "https://remote.example/users/pollcreator/outbox",
          public_key: "pubkey",
          local: false
        })

      question = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => poll_creator.ap_id,
        "context" => "https://remote.example/contexts/" <> Ecto.UUID.generate(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Remote poll",
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
        ],
        "closed" => "2030-12-31T23:59:59Z"
      }

      {:ok, poll} = Pipeline.ingest(question, local: false)

      assert {:ok, _updated} = Publish.vote_on_poll(voter, poll, [0])

      assert_enqueued(
        worker: DeliverActivity,
        queue: "federation_outgoing",
        args: %{
          "user_id" => voter.id,
          "inbox_url" => poll_creator.inbox
        }
      )
    end
  end
end
