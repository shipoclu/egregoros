defmodule Egregoros.PipelineDurabilityTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.TestActivities.Flaky

  test "persists a pending effect, retries it, and records completion outside canonical data" do
    activity = %{
      "id" => "https://remote.example/objects/flaky-#{System.unique_integer([:positive])}",
      "type" => "Flaky",
      "actor" => "https://remote.example/users/alice"
    }

    Process.put(:flaky_side_effect_result, {:error, :timeout})

    assert {:error, :timeout} = Pipeline.ingest_with(Flaky, activity, local: false)

    assert %Egregoros.Object{} = persisted = Objects.get_by_ap_id(activity["id"])
    assert persisted.internal["pipeline"]["side_effects"]["state"] == "pending"
    refute Map.has_key?(persisted.data, "pipeline")

    Process.put(:flaky_side_effect_result, :ok)

    assert {:ok, _completed} = Pipeline.ingest_with(Flaky, activity, local: false)

    assert Objects.get_by_ap_id(activity["id"]).internal["pipeline"]["side_effects"]["state"] ==
             "completed"

    assert Process.get(:flaky_side_effect_calls) == 2

    assert {:ok, replayed} = Pipeline.ingest_with(Flaky, activity, local: false)
    assert replayed.internal["pipeline"]["side_effects"]["state"] == "completed"
    assert Process.get(:flaky_side_effect_calls) == 2
  end
end
