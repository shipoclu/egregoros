defmodule Egregoros.Federation.DeliveryPayload do
  @moduledoc false

  def for_delivery(%{"object" => %{"type" => "Answer"} = object} = data) when is_map(data) do
    object =
      object
      |> Map.put("type", "Note")
      |> Map.delete("cc")

    data
    |> Map.put("object", object)
    |> Map.put("to", object |> Map.get("to", []) |> List.wrap())
    |> Map.put("cc", object |> Map.get("cc", []) |> List.wrap())
  end

  def for_delivery(data), do: data
end
