defmodule Egregoros.Objects.PollsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Objects.Polls
  alias Egregoros.Pipeline
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint

  describe "increase_vote_count/3" do
    setup do
      {:ok, alice} = Users.create_local_user("polls_test_alice")
      {:ok, bob} = Users.create_local_user("polls_test_bob")
      {:ok, carol} = Users.create_local_user("polls_test_carol")

      %{alice: alice, bob: bob, carol: carol}
    end

    test "increments vote count for a valid option", %{alice: alice, bob: bob} do
      poll = create_single_choice_poll(alice)

      assert {:ok, updated} = Polls.increase_vote_count(poll.ap_id, "Red", bob.ap_id)

      red_option = Enum.find(updated.data["oneOf"], &(&1["name"] == "Red"))
      assert red_option["replies"]["totalItems"] == 1
      assert bob.ap_id in updated.data["voters"]
    end

    test "prevents double-counting on single-choice poll (oneOf)", %{alice: alice, bob: bob} do
      poll = create_single_choice_poll(alice)

      # First vote succeeds
      assert {:ok, updated} = Polls.increase_vote_count(poll.ap_id, "Red", bob.ap_id)
      red_option = Enum.find(updated.data["oneOf"], &(&1["name"] == "Red"))
      assert red_option["replies"]["totalItems"] == 1

      # Second vote from same voter on different option is rejected
      assert :noop = Polls.increase_vote_count(poll.ap_id, "Blue", bob.ap_id)

      # Verify count didn't change
      reloaded = Objects.get_by_ap_id(poll.ap_id)
      blue_option = Enum.find(reloaded.data["oneOf"], &(&1["name"] == "Blue"))
      assert blue_option["replies"]["totalItems"] == 0
    end

    test "prevents replay attacks on single-choice poll", %{alice: alice, bob: bob} do
      poll = create_single_choice_poll(alice)

      # First vote
      assert {:ok, _} = Polls.increase_vote_count(poll.ap_id, "Red", bob.ap_id)

      # Replayed vote (same option, same voter) is rejected
      assert :noop = Polls.increase_vote_count(poll.ap_id, "Red", bob.ap_id)

      # Verify count is still 1
      reloaded = Objects.get_by_ap_id(poll.ap_id)
      red_option = Enum.find(reloaded.data["oneOf"], &(&1["name"] == "Red"))
      assert red_option["replies"]["totalItems"] == 1
    end

    test "allows different voters on single-choice poll", %{alice: alice, bob: bob, carol: carol} do
      poll = create_single_choice_poll(alice)

      assert {:ok, _} = Polls.increase_vote_count(poll.ap_id, "Red", bob.ap_id)
      assert {:ok, updated} = Polls.increase_vote_count(poll.ap_id, "Red", carol.ap_id)

      red_option = Enum.find(updated.data["oneOf"], &(&1["name"] == "Red"))
      assert red_option["replies"]["totalItems"] == 2
      assert bob.ap_id in updated.data["voters"]
      assert carol.ap_id in updated.data["voters"]
    end

    test "allows multiple options on multiple-choice poll (anyOf)", %{alice: alice, bob: bob} do
      poll = create_multiple_choice_poll(alice)

      # Bob votes on Option A
      assert {:ok, _} = Polls.increase_vote_count(poll.ap_id, "Option A", bob.ap_id)

      # Bob votes on Option B (allowed for anyOf)
      assert {:ok, updated} = Polls.increase_vote_count(poll.ap_id, "Option B", bob.ap_id)

      opt_a = Enum.find(updated.data["anyOf"], &(&1["name"] == "Option A"))
      opt_b = Enum.find(updated.data["anyOf"], &(&1["name"] == "Option B"))

      assert opt_a["replies"]["totalItems"] == 1
      assert opt_b["replies"]["totalItems"] == 1
    end

    test "prevents double-counting the same option on multiple-choice poll (anyOf)", %{
      alice: alice,
      bob: bob
    } do
      poll = create_multiple_choice_poll(alice)

      assert {:ok, _} = Polls.increase_vote_count(poll.ap_id, "Option A", bob.ap_id)

      assert :noop = Polls.increase_vote_count(poll.ap_id, "Option A", bob.ap_id)

      reloaded = Objects.get_by_ap_id(poll.ap_id)
      opt_a = Enum.find(reloaded.data["anyOf"], &(&1["name"] == "Option A"))
      assert opt_a["replies"]["totalItems"] == 1
    end

    test "returns :noop for non-existent poll", %{bob: bob} do
      assert :noop =
               Polls.increase_vote_count("https://example.com/nonexistent", "Red", bob.ap_id)
    end

    test "returns :noop for non-existent option", %{alice: alice, bob: bob} do
      poll = create_single_choice_poll(alice)

      assert :noop = Polls.increase_vote_count(poll.ap_id, "NonexistentOption", bob.ap_id)
    end
  end

  describe "update_from_remote/2" do
    setup do
      {:ok, alice} = Users.create_local_user("poll_refresh_alice")

      question = %{
        "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
        "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Refreshable poll",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{"name" => "A", "type" => "Note", "replies" => %{"totalItems" => 1}},
          %{"name" => "B", "type" => "Note", "replies" => %{"totalItems" => 2}}
        ]
      }

      {:ok, poll} = Pipeline.ingest(question, local: true)
      poll = Objects.get_by_ap_id(poll.ap_id)

      {:ok, poll} =
        Objects.update_object(poll, %{data: Map.put(poll.data, "voters", [alice.ap_id])})

      %{poll: poll}
    end

    test "updates counts when options match and preserves voters", %{poll: poll} do
      incoming = %{
        "id" => poll.ap_id,
        "type" => "Question",
        "actor" => poll.actor,
        "attributedTo" => poll.actor,
        "context" => poll.data["context"],
        "to" => poll.data["to"],
        "oneOf" => [
          %{"name" => "A", "type" => "Note", "replies" => %{"totalItems" => 5}},
          %{"name" => "B", "type" => "Note", "replies" => %{"totalItems" => 8}}
        ]
      }

      assert {:ok, updated} = Polls.update_from_remote(poll, incoming)

      [opt_a, opt_b] = updated.data["oneOf"]
      assert opt_a["replies"]["totalItems"] == 5
      assert opt_b["replies"]["totalItems"] == 8
      assert updated.data["voters"] == [poll.actor]
    end

    test "returns :noop when options change", %{poll: poll} do
      incoming = %{
        "id" => poll.ap_id,
        "type" => "Question",
        "actor" => poll.actor,
        "attributedTo" => poll.actor,
        "context" => poll.data["context"],
        "to" => poll.data["to"],
        "oneOf" => [
          %{"name" => "A", "type" => "Note", "replies" => %{"totalItems" => 5}},
          %{"name" => "C", "type" => "Note", "replies" => %{"totalItems" => 1}}
        ]
      }

      assert :noop = Polls.update_from_remote(poll, incoming)

      reloaded = Objects.get_by_ap_id(poll.ap_id)
      [opt_a, opt_b] = reloaded.data["oneOf"]
      assert opt_a["replies"]["totalItems"] == 1
      assert opt_b["replies"]["totalItems"] == 2
    end

    test "returns :noop when poll type changes", %{poll: poll} do
      incoming = %{
        "id" => poll.ap_id,
        "type" => "Question",
        "actor" => poll.actor,
        "attributedTo" => poll.actor,
        "context" => poll.data["context"],
        "to" => poll.data["to"],
        "anyOf" => [
          %{"name" => "A", "type" => "Note", "replies" => %{"totalItems" => 5}},
          %{"name" => "B", "type" => "Note", "replies" => %{"totalItems" => 8}}
        ]
      }

      assert :noop = Polls.update_from_remote(poll, incoming)
    end
  end

  # Helper functions

  defp create_single_choice_poll(owner) do
    question = %{
      "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
      "type" => "Question",
      "attributedTo" => owner.ap_id,
      "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "content" => "Single choice poll",
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
    poll
  end

  defp create_multiple_choice_poll(owner) do
    question = %{
      "id" => Endpoint.url() <> "/objects/" <> Ecto.UUID.generate(),
      "type" => "Question",
      "attributedTo" => owner.ap_id,
      "context" => Endpoint.url() <> "/contexts/" <> Ecto.UUID.generate(),
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "content" => "Multiple choice poll",
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
    poll
  end
end
