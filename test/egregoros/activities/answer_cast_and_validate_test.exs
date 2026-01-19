defmodule Egregoros.Activities.AnswerCastAndValidateTest do
  use ExUnit.Case, async: true

  alias Egregoros.Activities.Answer

  describe "cast_and_validate/1" do
    test "validates a valid answer" do
      answer = %{
        "id" => "https://example.com/objects/answer1",
        "type" => "Answer",
        "actor" => "https://example.com/users/alice",
        "attributedTo" => "https://example.com/users/alice",
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
        "inReplyTo" => "https://example.com/objects/poll1",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      assert {:ok, validated} = Answer.cast_and_validate(answer)
      assert validated["actor"] == "https://example.com/users/bob"
    end

    test "normalizes inReplyTo from object" do
      answer = %{
        "id" => "https://example.com/objects/answer3",
        "type" => "Answer",
        "actor" => "https://example.com/users/carol",
        "attributedTo" => "https://example.com/users/carol",
        "name" => "Green",
        "inReplyTo" => %{"id" => "https://example.com/objects/poll2"},
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      assert {:ok, validated} = Answer.cast_and_validate(answer)
      assert validated["inReplyTo"] == "https://example.com/objects/poll2"
    end

    test "rejects answer without name" do
      answer = %{
        "id" => "https://example.com/objects/invalid1",
        "type" => "Answer",
        "actor" => "https://example.com/users/dave",
        "attributedTo" => "https://example.com/users/dave",
        "inReplyTo" => "https://example.com/objects/poll1",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      assert {:error, %Ecto.Changeset{}} = Answer.cast_and_validate(answer)
    end

    test "rejects answer without inReplyTo" do
      answer = %{
        "id" => "https://example.com/objects/invalid2",
        "type" => "Answer",
        "actor" => "https://example.com/users/eve",
        "attributedTo" => "https://example.com/users/eve",
        "name" => "Red",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      assert {:error, %Ecto.Changeset{}} = Answer.cast_and_validate(answer)
    end

    test "rejects answer without attributedTo" do
      answer = %{
        "id" => "https://example.com/objects/invalid3",
        "type" => "Answer",
        "actor" => "https://example.com/users/frank",
        "name" => "Blue",
        "inReplyTo" => "https://example.com/objects/poll1",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      assert {:error, %Ecto.Changeset{}} = Answer.cast_and_validate(answer)
    end

    test "rejects non-Answer type" do
      answer = %{
        "id" => "https://example.com/objects/not-answer",
        "type" => "Note",
        "actor" => "https://example.com/users/frank",
        "attributedTo" => "https://example.com/users/frank",
        "name" => "Red",
        "inReplyTo" => "https://example.com/objects/poll1",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      assert {:error, %Ecto.Changeset{}} = Answer.cast_and_validate(answer)
    end

    test "rejects answer without recipients" do
      answer = %{
        "id" => "https://example.com/objects/invalid4",
        "type" => "Answer",
        "actor" => "https://example.com/users/gina",
        "attributedTo" => "https://example.com/users/gina",
        "name" => "Red",
        "inReplyTo" => "https://example.com/objects/poll1"
      }

      assert {:error, %Ecto.Changeset{}} = Answer.cast_and_validate(answer)
    end

    test "rejects answer when actor and attributedTo differ" do
      answer = %{
        "id" => "https://example.com/objects/invalid5",
        "type" => "Answer",
        "actor" => "https://example.com/users/hank",
        "attributedTo" => "https://example.com/users/ivan",
        "name" => "Red",
        "inReplyTo" => "https://example.com/objects/poll1",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      assert {:error, %Ecto.Changeset{}} = Answer.cast_and_validate(answer)
    end

    test "rejects answer when id host differs from actor host" do
      answer = %{
        "id" => "https://example.com/objects/invalid6",
        "type" => "Answer",
        "actor" => "https://evil.example/users/jane",
        "attributedTo" => "https://evil.example/users/jane",
        "name" => "Red",
        "inReplyTo" => "https://example.com/objects/poll1",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      assert {:error, %Ecto.Changeset{}} = Answer.cast_and_validate(answer)
    end
  end
end
