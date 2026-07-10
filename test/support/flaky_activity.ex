defmodule Egregoros.TestActivities.Flaky do
  alias Egregoros.Objects

  def cast_and_validate(activity), do: {:ok, activity}

  def ingest(activity, opts) do
    Objects.upsert_object(%{
      ap_id: activity["id"],
      type: activity["type"],
      actor: activity["actor"],
      data: activity,
      local: Keyword.get(opts, :local, true)
    })
  end

  def side_effects(_object, _opts) do
    Process.put(:flaky_side_effect_calls, Process.get(:flaky_side_effect_calls, 0) + 1)
    Process.get(:flaky_side_effect_result, :ok)
  end
end
