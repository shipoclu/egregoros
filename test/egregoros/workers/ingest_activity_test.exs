defmodule Egregoros.Workers.IngestActivityTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Workers.IngestActivity
  alias Egregoros.Workers.FetchActor
  alias Egregoros.Federation.Error

  test "ingests activities as remote objects" do
    job = %Oban.Job{
      args: %{
        "activity" => %{
          "id" => "https://remote.example/objects/1",
          "type" => "Note",
          "attributedTo" => "https://remote.example/users/alice",
          "content" => "Hello"
        }
      }
    }

    assert :ok = IngestActivity.perform(job)
  end

  test "enqueues actor fetches for mentions inside ingested activities" do
    job = %Oban.Job{
      args: %{
        "activity" => %{
          "id" => "https://remote.example/activities/create/1",
          "type" => "Create",
          "actor" => "https://remote.example/users/alice",
          "object" => %{
            "id" => "https://remote.example/objects/1",
            "type" => "Note",
            "attributedTo" => "https://remote.example/users/alice",
            "content" => "Hello @bob@remote2.example",
            "tag" => [
              %{
                "type" => "Mention",
                "href" => "https://remote2.example/users/bob",
                "name" => "@bob@remote2.example"
              }
            ]
          }
        }
      }
    }

    assert :ok = IngestActivity.perform(job)

    assert_enqueued(
      worker: FetchActor,
      args: %{"ap_id" => "https://remote2.example/users/bob"}
    )
  end

  test "discards invalid activities" do
    job = %Oban.Job{
      args: %{
        "activity" => %{"id" => "https://remote.example/objects/1", "type" => "Unknown"}
      }
    }

    assert {:discard, :unknown_type} = IngestActivity.perform(job)
  end

  test "rejects excessive actor fan-out before persistence or job creation" do
    activity = %{
      "id" => "https://remote.example/objects/too-many-recipients",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "Hello",
      "to" => Enum.map(1..101, &"https://remote.example/users/#{&1}")
    }

    assert {:discard, :activity_structure_limit} =
             IngestActivity.perform(%Oban.Job{args: %{"activity" => activity}})

    assert Egregoros.Objects.get_by_ap_id(activity["id"]) == nil
    refute_enqueued(worker: FetchActor)
  end

  test "discards jobs with invalid arguments" do
    assert {:discard, :invalid_args} = IngestActivity.perform(%Oban.Job{args: %{}})
    assert {:discard, :invalid_args} = IngestActivity.perform(%Oban.Job{args: %{"activity" => 1}})
  end

  test "classifies validation errors as permanent and infrastructure errors as transient" do
    assert Error.classify(:unknown_type) == :permanent
    assert Error.classify(:unauthorized_update) == :permanent
    assert Error.classify(:timeout) == :transient

    assert Error.classify(%DBConnection.ConnectionError{message: "database unavailable"}) ==
             :transient

    assert Error.classify(Ecto.Changeset.change(%Egregoros.Object{})) == :permanent
  end
end
