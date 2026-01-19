defmodule Egregoros.Activities.QuestionCastAndValidateTest do
  use ExUnit.Case, async: true

  alias Egregoros.Activities.Question

  describe "cast_and_validate/1" do
    test "validates a valid single-choice poll (oneOf)" do
      question = %{
        "id" => "https://example.com/objects/poll1",
        "type" => "Question",
        "attributedTo" => "https://example.com/users/alice",
        "context" => "https://example.com/contexts/poll1",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "What's your favorite color?",
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
          },
          %{
            "name" => "Green",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 2}
          }
        ],
        "closed" => "2025-12-31T23:59:59Z"
      }

      assert {:ok, validated} = Question.cast_and_validate(question)
      assert validated["actor"] == "https://example.com/users/alice"
      assert validated["type"] == "Question"
      assert length(validated["oneOf"]) == 3
    end

    test "validates a valid multiple-choice poll (anyOf)" do
      question = %{
        "id" => "https://example.com/objects/poll2",
        "type" => "Question",
        "attributedTo" => "https://example.com/users/bob",
        "context" => "https://example.com/contexts/poll2",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Select all that apply",
        "anyOf" => [
          %{"name" => "Option A"},
          %{"name" => "Option B"}
        ]
      }

      assert {:ok, validated} = Question.cast_and_validate(question)
      assert validated["actor"] == "https://example.com/users/bob"
      assert length(validated["anyOf"]) == 2
    end

    test "copies attributedTo into actor" do
      question = %{
        "id" => "https://example.com/objects/poll3",
        "type" => "Question",
        "attributedTo" => "https://example.com/users/carol",
        "context" => "https://example.com/contexts/poll3",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Test poll",
        "oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}]
      }

      assert {:ok, validated} = Question.cast_and_validate(question)
      assert validated["actor"] == "https://example.com/users/carol"
    end

    test "normalizes endTime to closed" do
      question = %{
        "id" => "https://example.com/objects/poll4",
        "type" => "Question",
        "actor" => "https://example.com/users/dave",
        "attributedTo" => "https://example.com/users/dave",
        "context" => "https://example.com/contexts/poll4",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Poll with endTime",
        "oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}],
        "endTime" => "2025-06-15T12:00:00Z"
      }

      assert {:ok, validated} = Question.cast_and_validate(question)
      assert validated["closed"] == "2025-06-15T12:00:00Z"
    end

    test "normalizes poll options with default type and replies" do
      question = %{
        "id" => "https://example.com/objects/poll5",
        "type" => "Question",
        "actor" => "https://example.com/users/eve",
        "attributedTo" => "https://example.com/users/eve",
        "context" => "https://example.com/contexts/poll5",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Simple poll",
        "oneOf" => [
          %{"name" => "Option 1"},
          %{"name" => "Option 2"}
        ]
      }

      assert {:ok, validated} = Question.cast_and_validate(question)

      [opt1, opt2] = validated["oneOf"]
      assert opt1["type"] == "Note"
      assert opt1["replies"]["type"] == "Collection"
      assert opt1["replies"]["totalItems"] == 0
      assert opt2["type"] == "Note"
      assert opt2["replies"]["totalItems"] == 0
    end

    test "rejects question without oneOf or anyOf" do
      question = %{
        "id" => "https://example.com/objects/invalid",
        "type" => "Question",
        "actor" => "https://example.com/users/frank",
        "attributedTo" => "https://example.com/users/frank",
        "context" => "https://example.com/contexts/invalid",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "No options poll"
      }

      assert {:error, %Ecto.Changeset{}} = Question.cast_and_validate(question)
    end

    test "rejects question with empty options" do
      question = %{
        "id" => "https://example.com/objects/invalid2",
        "type" => "Question",
        "actor" => "https://example.com/users/grace",
        "attributedTo" => "https://example.com/users/grace",
        "context" => "https://example.com/contexts/invalid2",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Empty options",
        "oneOf" => []
      }

      assert {:error, %Ecto.Changeset{}} = Question.cast_and_validate(question)
    end

    test "rejects question with options missing name" do
      question = %{
        "id" => "https://example.com/objects/invalid3",
        "type" => "Question",
        "actor" => "https://example.com/users/heidi",
        "attributedTo" => "https://example.com/users/heidi",
        "context" => "https://example.com/contexts/invalid3",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Bad options",
        "oneOf" => [
          %{"type" => "Note"},
          %{"name" => "Valid"}
        ]
      }

      assert {:error, %Ecto.Changeset{}} = Question.cast_and_validate(question)
    end

    test "rejects non-Question type" do
      question = %{
        "id" => "https://example.com/objects/not-a-poll",
        "type" => "Note",
        "actor" => "https://example.com/users/ivan",
        "attributedTo" => "https://example.com/users/ivan",
        "context" => "https://example.com/contexts/not-a-poll",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Not a poll",
        "oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}]
      }

      assert {:error, %Ecto.Changeset{}} = Question.cast_and_validate(question)
    end

    test "handles contentMap normalization" do
      question = %{
        "id" => "https://example.com/objects/poll6",
        "type" => "Question",
        "actor" => "https://example.com/users/judy",
        "attributedTo" => "https://example.com/users/judy",
        "context" => "https://example.com/contexts/poll6",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "contentMap" => %{"en" => "English content", "de" => "German content"},
        "oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}]
      }

      assert {:ok, validated} = Question.cast_and_validate(question)
      assert validated["content"] == "English content"
    end

    test "preserves voters array" do
      question = %{
        "id" => "https://example.com/objects/poll7",
        "type" => "Question",
        "actor" => "https://example.com/users/kate",
        "attributedTo" => "https://example.com/users/kate",
        "context" => "https://example.com/contexts/poll7",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Poll with voters",
        "oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}],
        "voters" => ["https://example.com/users/voter1", "https://example.com/users/voter2"]
      }

      assert {:ok, validated} = Question.cast_and_validate(question)

      assert validated["voters"] == [
               "https://example.com/users/voter1",
               "https://example.com/users/voter2"
             ]
    end

    test "rejects question without recipients" do
      question = %{
        "id" => "https://example.com/objects/invalid4",
        "type" => "Question",
        "actor" => "https://example.com/users/lara",
        "attributedTo" => "https://example.com/users/lara",
        "context" => "https://example.com/contexts/invalid4",
        "content" => "No recipients",
        "oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}]
      }

      assert {:error, %Ecto.Changeset{}} = Question.cast_and_validate(question)
    end

    test "rejects question when actor and attributedTo differ" do
      question = %{
        "id" => "https://example.com/objects/invalid5",
        "type" => "Question",
        "actor" => "https://example.com/users/mallory",
        "attributedTo" => "https://example.com/users/alice",
        "context" => "https://example.com/contexts/invalid5",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Mismatched actor",
        "oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}]
      }

      assert {:error, %Ecto.Changeset{}} = Question.cast_and_validate(question)
    end

    test "rejects question when id host differs from actor host" do
      question = %{
        "id" => "https://example.com/objects/invalid6",
        "type" => "Question",
        "actor" => "https://evil.example/users/nina",
        "attributedTo" => "https://evil.example/users/nina",
        "context" => "https://example.com/contexts/invalid6",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Host mismatch",
        "oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}]
      }

      assert {:error, %Ecto.Changeset{}} = Question.cast_and_validate(question)
    end
  end
end
