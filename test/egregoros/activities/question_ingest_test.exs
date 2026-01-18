defmodule Egregoros.Activities.QuestionIngestTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Users

  describe "Question ingestion" do
    test "ingests a single-choice Question (oneOf)" do
      {:ok, alice} = Users.create_local_user("alice")

      question = %{
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => alice.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "What's your favorite color?",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{"name" => "Red", "type" => "Note", "replies" => %{"type" => "Collection", "totalItems" => 0}},
          %{"name" => "Blue", "type" => "Note", "replies" => %{"type" => "Collection", "totalItems" => 0}},
          %{"name" => "Green", "type" => "Note", "replies" => %{"type" => "Collection", "totalItems" => 0}}
        ],
        "closed" => "2030-12-31T23:59:59Z"
      }

      assert {:ok, object} = Pipeline.ingest(question, local: true)
      assert object.type == "Question"
      assert object.actor == alice.ap_id
      assert length(object.data["oneOf"]) == 3
      assert object.data["closed"] == "2030-12-31T23:59:59Z"
    end

    test "ingests a multiple-choice Question (anyOf)" do
      {:ok, bob} = Users.create_local_user("bob")

      question = %{
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => bob.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Select all that apply",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "anyOf" => [
          %{"name" => "Option A"},
          %{"name" => "Option B"},
          %{"name" => "Option C"}
        ]
      }

      assert {:ok, object} = Pipeline.ingest(question, local: true)
      assert object.type == "Question"
      assert length(object.data["anyOf"]) == 3
    end

    test "normalizes poll options with default replies" do
      {:ok, carol} = Users.create_local_user("carol")

      question = %{
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => carol.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Simple poll",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{"name" => "Yes"},
          %{"name" => "No"}
        ]
      }

      assert {:ok, object} = Pipeline.ingest(question, local: true)

      [opt1, opt2] = object.data["oneOf"]
      assert opt1["replies"]["totalItems"] == 0
      assert opt2["replies"]["totalItems"] == 0
    end

    test "Question appears in public timeline" do
      {:ok, dave} = Users.create_local_user("dave")

      question = %{
        "id" => "https://example.com/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => dave.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "content" => "Public poll",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [%{"name" => "Yes"}, %{"name" => "No"}]
      }

      assert {:ok, object} = Pipeline.ingest(question, local: true)

      statuses = Objects.list_public_statuses(limit: 10)
      assert Enum.any?(statuses, &(&1.id == object.id))
    end
  end
end
