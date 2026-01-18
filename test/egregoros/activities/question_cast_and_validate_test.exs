defmodule Egregoros.Activities.QuestionCastAndValidateTest do
  use ExUnit.Case, async: true

  alias Egregoros.Activities.Question

  describe "cast_and_validate/1" do
    test "validates a valid single-choice poll (oneOf)" do
      question = %{
        "id" => "https://example.com/objects/poll1",
        "type" => "Question",
        "attributedTo" => "https://example.com/users/alice",
        "content" => "What's your favorite color?",
        "oneOf" => [
          %{"name" => "Red", "type" => "Note", "replies" => %{"type" => "Collection", "totalItems" => 5}},
          %{"name" => "Blue", "type" => "Note", "replies" => %{"type" => "Collection", "totalItems" => 3}},
          %{"name" => "Green", "type" => "Note", "replies" => %{"type" => "Collection", "totalItems" => 2}}
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
        "content" => "No options poll"
      }

      assert {:error, %Ecto.Changeset{}} = Question.cast_and_validate(question)
    end

    test "rejects question with empty options" do
      question = %{
        "id" => "https://example.com/objects/invalid2",
        "type" => "Question",
        "actor" => "https://example.com/users/grace",
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
        "content" => "Poll with voters",
        "oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}],
        "voters" => ["https://example.com/users/voter1", "https://example.com/users/voter2"]
      }

      assert {:ok, validated} = Question.cast_and_validate(question)
      assert validated["voters"] == ["https://example.com/users/voter1", "https://example.com/users/voter2"]
    end
  end
end
