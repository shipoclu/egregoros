defmodule PleromaRedux.TestSupport.PipelineCastAndValidateProbe do
  def type, do: "PipelineCastAndValidateProbe"

  def cast_and_validate(activity) when is_map(activity) do
    activity =
      activity
      |> Map.put("validated?", true)

    {:ok, activity}
  end

  def normalize(_activity) do
    raise "normalize/1 must not be called when cast_and_validate/1 is available"
  end

  def validate(_activity) do
    raise "validate/1 must not be called when cast_and_validate/1 is available"
  end

  def ingest(activity, _opts), do: {:ok, activity}

  def side_effects(_object, _opts), do: :ok
end
