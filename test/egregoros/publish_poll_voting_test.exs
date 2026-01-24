defmodule Egregoros.PublishPollVotingTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Publish
  alias Egregoros.Publish.Polls
  alias Egregoros.User
  alias Egregoros.Users

  describe "vote_on_poll/3" do
    test "returns :invalid_poll for non-Question objects" do
      user = %User{}

      not_a_poll = %Object{
        type: "Note",
        actor: "https://example.com/users/alice",
        ap_id: "https://example.com/objects/1",
        data: %{}
      }

      assert {:error, :invalid_poll} = Polls.vote_on_poll(user, not_a_poll, [0])
    end

    test "returns :own_poll when voting on your own poll" do
      user = %User{ap_id: "https://example.com/users/alice"}

      question = %Object{
        type: "Question",
        actor: user.ap_id,
        ap_id: "https://example.com/objects/q1",
        data: %{"oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}]}
      }

      assert {:error, :own_poll} = Polls.vote_on_poll(user, question, [0])
    end

    test "returns :poll_expired when poll is closed in the past" do
      user = %User{ap_id: nil}

      closed =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.to_iso8601()

      question = %Object{
        type: "Question",
        actor: "https://example.com/users/alice",
        ap_id: "https://example.com/objects/q2",
        data: %{
          "closed" => closed,
          "oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}]
        }
      }

      assert {:error, :poll_expired} = Polls.vote_on_poll(user, question, [0])
    end

    test "rejects multiple choices for oneOf polls and coerces choice indices" do
      user = %User{ap_id: nil}

      question = %Object{
        type: "Question",
        actor: "https://example.com/users/alice",
        ap_id: "https://example.com/objects/q3",
        data: %{"oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}]}
      }

      assert {:error, :multiple_choices_not_allowed} =
               Polls.vote_on_poll(user, question, ["0", "1"])
    end

    test "returns :invalid_choice when choices are empty or invalid" do
      user = %User{ap_id: nil}

      question = %Object{
        type: "Question",
        actor: "https://example.com/users/alice",
        ap_id: "https://example.com/objects/q4",
        data: %{"oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}]}
      }

      assert {:error, :invalid_choice} = Polls.vote_on_poll(user, question, [:nope])
    end

    test "returns :invalid_choice when an index is out of range for anyOf polls" do
      user = %User{ap_id: nil}

      question = %Object{
        type: "Question",
        actor: "https://example.com/users/alice",
        ap_id: "https://example.com/objects/q5",
        data: %{
          "closed" => "not-a-datetime",
          "anyOf" => [%{"name" => "Yes"}, %{"name" => "No"}]
        }
      }

      assert {:error, :invalid_choice} = Polls.vote_on_poll(user, question, [2])
    end

    test "treats non-binary closed values as not expired and rejects invalid choice strings" do
      user = %User{ap_id: nil}

      question = %Object{
        type: "Question",
        actor: "https://example.com/users/alice",
        ap_id: "https://example.com/objects/q6",
        data: %{
          "closed" => 123,
          "oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}]
        }
      }

      assert {:error, :invalid_choice} = Polls.vote_on_poll(user, question, ["nope"])
    end

    test "creates Answer objects and prevents double voting" do
      {:ok, author} = Users.create_local_user("poll_vote_author")
      {:ok, voter} = Users.create_local_user("poll_vote_voter")

      assert {:ok, create} =
               Publish.post_poll(author, "Pick one", %{
                 "options" => ["Yes", "No"],
                 "multiple" => false,
                 "expires_in" => 3600
               })

      question = Objects.get_by_ap_id(create.object)
      assert question.type == "Question"

      assert {:ok, _question} = Polls.vote_on_poll(voter, question, [0])

      assert %Object{type: "Answer"} =
               Objects.get_by_type_actor_object("Answer", voter.ap_id, question.ap_id)

      assert {:error, :already_voted} = Polls.vote_on_poll(voter, question, [1])
    end
  end
end
