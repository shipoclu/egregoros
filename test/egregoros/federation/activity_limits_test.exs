defmodule Egregoros.Federation.ActivityLimitsTest do
  use ExUnit.Case, async: true

  alias Egregoros.Federation.ActivityLimits

  test "accepts structures at the documented limits" do
    activity = %{
      "to" => Enum.map(1..100, &"https://remote.example/users/#{&1}"),
      "tag" => Enum.map(1..100, &%{"type" => "Hashtag", "name" => "tag#{&1}"}),
      "attachment" => Enum.map(1..16, &%{"type" => "Document", "id" => "file#{&1}"})
    }

    assert :ok = ActivityLimits.validate(activity)
  end

  test "rejects excessive recipients, tags, attachments, collection items, and nesting" do
    assert {:error, :activity_structure_limit} =
             ActivityLimits.validate(%{
               "to" => Enum.map(1..101, &"https://remote.example/users/#{&1}")
             })

    assert {:error, :activity_structure_limit} =
             ActivityLimits.validate(%{"tag" => List.duplicate(%{}, 101)})

    assert {:error, :activity_structure_limit} =
             ActivityLimits.validate(%{"attachment" => List.duplicate(%{}, 17)})

    assert {:error, :activity_structure_limit} =
             ActivityLimits.validate(%{"orderedItems" => List.duplicate(%{}, 201)})

    assert {:error, :activity_structure_limit} =
             ActivityLimits.validate(%{"unknownArray" => List.duplicate("value", 501)})

    nested = Enum.reduce(1..21, %{"type" => "Note"}, fn _, acc -> %{"object" => acc} end)
    assert {:error, :activity_structure_limit} = ActivityLimits.validate(nested)
  end
end
