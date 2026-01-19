defmodule Egregoros.Activities.AnswerIngestTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint

  describe "Answer ingestion and vote counting" do
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
        ]
      }

      {:ok, poll} = Pipeline.ingest(question, local: true)

      %{alice: alice, bob: bob, carol: carol, poll: poll}
    end

    test "ingests an Answer object", %{poll: poll, bob: bob} do
      answer = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Answer",
        "attributedTo" => bob.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "name" => "Red",
        "inReplyTo" => poll.ap_id
      }

      assert {:ok, object} = Pipeline.ingest(answer, local: true)
      assert object.type == "Answer"
      assert object.actor == bob.ap_id
      assert object.data["name"] == "Red"
      assert object.object == poll.ap_id
    end

    test "side_effects increases vote count on Question", %{poll: poll, bob: bob} do
      answer = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Answer",
        "attributedTo" => bob.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "name" => "Red",
        "inReplyTo" => poll.ap_id
      }

      # Pipeline.ingest automatically calls side_effects
      {:ok, _answer_object} = Pipeline.ingest(answer, local: true)

      # Reload the poll
      updated_poll = Objects.get_by_ap_id(poll.ap_id)

      red_option = Enum.find(updated_poll.data["oneOf"], &(&1["name"] == "Red"))
      assert red_option["replies"]["totalItems"] == 1
    end

    test "side_effects records voter metadata in internal state", %{poll: poll, bob: bob} do
      answer = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Answer",
        "attributedTo" => bob.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "name" => "Blue",
        "inReplyTo" => poll.ap_id
      }

      # Pipeline.ingest automatically calls side_effects
      {:ok, _answer_object} = Pipeline.ingest(answer, local: true)

      updated_poll = Objects.get_by_ap_id(poll.ap_id)
      assert bob.ap_id in get_in(updated_poll.internal, ["poll", "voters"])
    end

    test "multiple votes from different users are counted", %{poll: poll, bob: bob, carol: carol} do
      # Bob votes for Red
      answer1 = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Answer",
        "attributedTo" => bob.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "name" => "Red",
        "inReplyTo" => poll.ap_id
      }

      # Pipeline.ingest automatically calls side_effects
      {:ok, _answer1_obj} = Pipeline.ingest(answer1, local: true)

      # Carol votes for Red too
      answer2 = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Answer",
        "attributedTo" => carol.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "name" => "Red",
        "inReplyTo" => poll.ap_id
      }

      # Pipeline.ingest automatically calls side_effects
      {:ok, _answer2_obj} = Pipeline.ingest(answer2, local: true)

      updated_poll = Objects.get_by_ap_id(poll.ap_id)

      red_option = Enum.find(updated_poll.data["oneOf"], &(&1["name"] == "Red"))
      assert red_option["replies"]["totalItems"] == 2

      assert bob.ap_id in get_in(updated_poll.internal, ["poll", "voters"])
      assert carol.ap_id in get_in(updated_poll.internal, ["poll", "voters"])
    end

    test "vote for non-existent option does nothing", %{poll: poll, bob: bob} do
      answer = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Answer",
        "attributedTo" => bob.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "name" => "Purple",
        "inReplyTo" => poll.ap_id
      }

      # Pipeline.ingest automatically calls side_effects
      {:ok, _answer_object} = Pipeline.ingest(answer, local: true)

      # Poll should be unchanged
      updated_poll = Objects.get_by_ap_id(poll.ap_id)

      for option <- updated_poll.data["oneOf"] do
        assert option["replies"]["totalItems"] == 0
      end
    end

    test "vote for non-existent poll does nothing", %{bob: bob} do
      answer = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Answer",
        "attributedTo" => bob.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "name" => "Red",
        "inReplyTo" => "https://example.com/objects/nonexistent"
      }

      # Pipeline.ingest automatically calls side_effects - should complete without error
      assert {:ok, _answer_object} = Pipeline.ingest(answer, local: true)
    end
  end

  describe "Create activities with poll answers" do
    test "ingests remote Create with Note answer and updates poll counts" do
      {:ok, owner} = Users.create_local_user("poll_owner_create")

      question = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => owner.ap_id,
        "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Remote vote poll",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{"name" => "yes", "replies" => %{"type" => "Collection", "totalItems" => 0}},
          %{"name" => "no", "replies" => %{"type" => "Collection", "totalItems" => 0}}
        ]
      }

      {:ok, poll} = Pipeline.ingest(question, local: true)

      voter_ap_id = "https://remote.example/users/voter"

      activity = %{
        "id" => "https://remote.example/activities/" <> Ecto.UUID.generate(),
        "type" => "Create",
        "actor" => voter_ap_id,
        "to" => [],
        "cc" => [],
        "object" => %{
          "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
          "type" => "Note",
          "actor" => voter_ap_id,
          "attributedTo" => voter_ap_id,
          "name" => "no",
          "inReplyTo" => poll.ap_id,
          "cc" => [owner.ap_id],
          "to" => []
        }
      }

      assert {:ok, _create} =
               Pipeline.ingest(activity, local: false, inbox_user_ap_id: owner.ap_id)

      updated_poll = Objects.get_by_ap_id(poll.ap_id)
      option = Enum.find(updated_poll.data["oneOf"], &(&1["name"] == "no"))
      assert option["replies"]["totalItems"] == 1

      assert Objects.get_by_type_actor_object("Answer", voter_ap_id, poll.ap_id)
    end
  end

  describe "remote Answer inbox targeting" do
    setup do
      {:ok, alice} = Users.create_local_user("remote_alice")

      # Create a public poll
      public_question = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => "https://remote.example/users/pollcreator",
        "context" => "https://remote.example/contexts/" <> Ecto.UUID.generate(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [alice.ap_id <> "/followers"],
        "content" => "Public poll",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{"name" => "Yes", "replies" => %{"totalItems" => 0}},
          %{"name" => "No", "replies" => %{"totalItems" => 0}}
        ]
      }

      {:ok, public_poll} = Pipeline.ingest(public_question, local: false)

      # Create a followers-only poll
      followers_question = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => "https://remote.example/users/pollcreator",
        "context" => "https://remote.example/contexts/" <> Ecto.UUID.generate(),
        "to" => ["https://remote.example/users/pollcreator/followers"],
        "content" => "Followers-only poll",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{"name" => "A", "replies" => %{"totalItems" => 0}},
          %{"name" => "B", "replies" => %{"totalItems" => 0}}
        ]
      }

      {:ok, followers_poll} = Pipeline.ingest(followers_question, local: false)

      %{alice: alice, public_poll: public_poll, followers_poll: followers_poll}
    end

    test "accepts remote Answer for public poll", %{public_poll: poll} do
      answer = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Answer",
        "actor" => "https://remote.example/users/voter",
        "attributedTo" => "https://remote.example/users/voter",
        "to" => ["https://remote.example/users/pollcreator"],
        "name" => "Yes",
        "inReplyTo" => poll.ap_id
      }

      assert {:ok, object} = Pipeline.ingest(answer, local: false)
      assert object.type == "Answer"

      # Verify vote was counted
      updated_poll = Objects.get_by_ap_id(poll.ap_id)
      yes_option = Enum.find(updated_poll.data["oneOf"], &(&1["name"] == "Yes"))
      assert yes_option["replies"]["totalItems"] == 1
    end

    test "rejects remote Answer for followers-only poll when voter is not a follower", %{
      followers_poll: poll
    } do
      answer = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Answer",
        "actor" => "https://remote.example/users/follower",
        "attributedTo" => "https://remote.example/users/follower",
        "to" => ["https://remote.example/users/pollcreator"],
        "name" => "A",
        "inReplyTo" => poll.ap_id
      }

      assert {:error, :voter_not_permitted} = Pipeline.ingest(answer, local: false)
    end

    test "accepts remote Answer for followers-only poll when voter follows poll creator", %{
      followers_poll: poll
    } do
      voter_ap_id = "https://remote.example/users/follower"
      poll_creator_ap_id = "https://remote.example/users/pollcreator"

      assert {:ok, _relationship} =
               Relationships.upsert_relationship(%{
                 type: "Follow",
                 actor: voter_ap_id,
                 object: poll_creator_ap_id
               })

      answer = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Answer",
        "actor" => voter_ap_id,
        "attributedTo" => voter_ap_id,
        "to" => [poll_creator_ap_id],
        "name" => "A",
        "inReplyTo" => poll.ap_id
      }

      assert {:ok, object} = Pipeline.ingest(answer, local: false)
      assert object.type == "Answer"
    end

    test "rejects remote Answer for unknown poll", %{} do
      answer = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Answer",
        "actor" => "https://remote.example/users/voter",
        "attributedTo" => "https://remote.example/users/voter",
        "to" => ["https://remote.example/users/pollcreator"],
        "name" => "Yes",
        "inReplyTo" => "https://unknown.example/objects/nonexistent"
      }

      assert {:error, :question_not_found} = Pipeline.ingest(answer, local: false)
    end

    test "rejects remote Answer when voter not permitted", %{alice: alice} do
      # Create a private poll addressed only to specific users
      private_question = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => "https://remote.example/users/pollcreator",
        "context" => "https://remote.example/contexts/" <> Ecto.UUID.generate(),
        "to" => [alice.ap_id],
        "content" => "Private poll for alice only",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{"name" => "X", "replies" => %{"totalItems" => 0}},
          %{"name" => "Y", "replies" => %{"totalItems" => 0}}
        ]
      }

      {:ok, private_poll} = Pipeline.ingest(private_question, local: false)

      # Someone not in the audience tries to vote
      answer = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Answer",
        "actor" => "https://remote.example/users/unauthorized",
        "attributedTo" => "https://remote.example/users/unauthorized",
        "to" => ["https://remote.example/users/pollcreator"],
        "name" => "X",
        "inReplyTo" => private_poll.ap_id
      }

      assert {:error, :voter_not_permitted} = Pipeline.ingest(answer, local: false)
    end

    test "accepts remote Answer when voter is directly addressed in poll", %{alice: _alice} do
      voter_ap_id = "https://remote.example/users/alice"

      # Create a poll addressed to alice
      dm_question = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => "https://remote.example/users/pollcreator",
        "context" => "https://remote.example/contexts/" <> Ecto.UUID.generate(),
        "to" => [voter_ap_id],
        "content" => "Poll for alice",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{"name" => "Option1", "replies" => %{"totalItems" => 0}},
          %{"name" => "Option2", "replies" => %{"totalItems" => 0}}
        ]
      }

      {:ok, dm_poll} = Pipeline.ingest(dm_question, local: false)

      # Alice votes
      answer = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Answer",
        "actor" => voter_ap_id,
        "attributedTo" => voter_ap_id,
        "to" => ["https://remote.example/users/pollcreator"],
        "name" => "Option1",
        "inReplyTo" => dm_poll.ap_id
      }

      assert {:ok, object} = Pipeline.ingest(answer, local: false)
      assert object.type == "Answer"
    end
  end

  describe "increase_vote_count/3" do
    test "increases vote count for matching option" do
      {:ok, alice} = Users.create_local_user("vote_alice")
      {:ok, voter} = Users.create_local_user("vote_voter")

      question = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
        "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Test poll",
        "oneOf" => [
          %{"name" => "A", "replies" => %{"totalItems" => 5}},
          %{"name" => "B", "replies" => %{"totalItems" => 3}}
        ]
      }

      {:ok, poll} = Pipeline.ingest(question, local: true)

      {:ok, updated} = Objects.increase_vote_count(poll.ap_id, "A", voter.ap_id)

      opt_a = Enum.find(updated.data["oneOf"], &(&1["name"] == "A"))
      opt_b = Enum.find(updated.data["oneOf"], &(&1["name"] == "B"))

      assert opt_a["replies"]["totalItems"] == 6
      assert opt_b["replies"]["totalItems"] == 3
      assert voter.ap_id in get_in(updated.internal, ["poll", "voters"])
    end

    test "returns :noop for non-existent question" do
      result =
        Objects.increase_vote_count(
          "https://fake.example/poll",
          "A",
          "https://fake.example/voter"
        )

      assert result == :noop
    end

    test "returns :noop for non-matching option name" do
      {:ok, alice} = Users.create_local_user("noop_alice")

      question = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
        "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Test poll",
        "oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}]
      }

      {:ok, poll} = Pipeline.ingest(question, local: true)

      result = Objects.increase_vote_count(poll.ap_id, "Maybe", "https://example.com/voter")
      assert result == :noop
    end

    test "handles anyOf (multiple choice) polls" do
      {:ok, alice} = Users.create_local_user("anyof_alice")
      {:ok, voter} = Users.create_local_user("anyof_voter")

      question = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
        "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Multiple choice poll",
        "anyOf" => [
          %{"name" => "Option 1", "replies" => %{"totalItems" => 0}},
          %{"name" => "Option 2", "replies" => %{"totalItems" => 0}}
        ]
      }

      {:ok, poll} = Pipeline.ingest(question, local: true)

      {:ok, updated} = Objects.increase_vote_count(poll.ap_id, "Option 1", voter.ap_id)

      opt1 = Enum.find(updated.data["anyOf"], &(&1["name"] == "Option 1"))
      assert opt1["replies"]["totalItems"] == 1
    end
  end
end
