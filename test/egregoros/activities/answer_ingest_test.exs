defmodule Egregoros.Activities.AnswerIngestTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Users

  describe "Answer ingestion and vote counting" do
    setup do
      {:ok, alice} = Users.create_local_user("alice")
      {:ok, bob} = Users.create_local_user("bob")
      {:ok, carol} = Users.create_local_user("carol")

      question = %{
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
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
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
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
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
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

    test "side_effects adds voter to voters array", %{poll: poll, bob: bob} do
      answer = %{
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
        "type" => "Answer",
        "attributedTo" => bob.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "name" => "Blue",
        "inReplyTo" => poll.ap_id
      }

      # Pipeline.ingest automatically calls side_effects
      {:ok, _answer_object} = Pipeline.ingest(answer, local: true)

      updated_poll = Objects.get_by_ap_id(poll.ap_id)
      assert bob.ap_id in updated_poll.data["voters"]
    end

    test "multiple votes from different users are counted", %{poll: poll, bob: bob, carol: carol} do
      # Bob votes for Red
      answer1 = %{
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
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
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
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

      assert bob.ap_id in updated_poll.data["voters"]
      assert carol.ap_id in updated_poll.data["voters"]
    end

    test "vote for non-existent option does nothing", %{poll: poll, bob: bob} do
      answer = %{
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
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
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
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

  describe "increase_vote_count/3" do
    test "increases vote count for matching option" do
      {:ok, alice} = Users.create_local_user("vote_alice")
      {:ok, voter} = Users.create_local_user("vote_voter")

      question = %{
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
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
      assert voter.ap_id in updated.data["voters"]
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
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
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
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
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
