defmodule Egregoros.Activities.AnswerCastAndValidateTest do
  use ExUnit.Case, async: true

  alias Egregoros.Activities.Answer

  describe "cast_and_validate/1" do
    test "validates a valid answer" do
      answer = %{
        "id" => "https://example.com/objects/answer1",
        "type" => "Answer",
        "actor" => "https://example.com/users/alice",
        "name" => "Red",
        "inReplyTo" => "https://example.com/objects/poll1",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      assert {:ok, validated} = Answer.cast_and_validate(answer)
      assert validated["actor"] == "https://example.com/users/alice"
      assert validated["name"] == "Red"
      assert validated["inReplyTo"] == "https://example.com/objects/poll1"
    end

    test "copies attributedTo into actor" do
      answer = %{
        "id" => "https://example.com/objects/answer2",
        "type" => "Answer",
        "attributedTo" => "https://example.com/users/bob",
        "name" => "Blue",
        "inReplyTo" => "https://example.com/objects/poll1"
      }

      assert {:ok, validated} = Answer.cast_and_validate(answer)
      assert validated["actor"] == "https://example.com/users/bob"
    end

    test "normalizes inReplyTo from object" do
      answer = %{
        "id" => "https://example.com/objects/answer3",
        "type" => "Answer",
        "actor" => "https://example.com/users/carol",
        "name" => "Green",
        "inReplyTo" => %{"id" => "https://example.com/objects/poll2"}
      }

      assert {:ok, validated} = Answer.cast_and_validate(answer)
      assert validated["inReplyTo"] == "https://example.com/objects/poll2"
    end

    test "rejects answer without name" do
      answer = %{
        "id" => "https://example.com/objects/invalid1",
        "type" => "Answer",
        "actor" => "https://example.com/users/dave",
        "inReplyTo" => "https://example.com/objects/poll1"
      }

      assert {:error, %Ecto.Changeset{}} = Answer.cast_and_validate(answer)
    end

    test "rejects answer without inReplyTo" do
      answer = %{
        "id" => "https://example.com/objects/invalid2",
        "type" => "Answer",
        "actor" => "https://example.com/users/eve",
        "name" => "Red"
      }

      assert {:error, %Ecto.Changeset{}} = Answer.cast_and_validate(answer)
    end

    test "rejects answer without actor" do
      answer = %{
        "id" => "https://example.com/objects/invalid3",
        "type" => "Answer",
        "name" => "Blue",
        "inReplyTo" => "https://example.com/objects/poll1"
      }

      assert {:error, %Ecto.Changeset{}} = Answer.cast_and_validate(answer)
    end

    test "rejects non-Answer type" do
      answer = %{
        "id" => "https://example.com/objects/not-answer",
        "type" => "Note",
        "actor" => "https://example.com/users/frank",
        "name" => "Red",
        "inReplyTo" => "https://example.com/objects/poll1"
      }

      assert {:error, %Ecto.Changeset{}} = Answer.cast_and_validate(answer)
    end
  end
end
