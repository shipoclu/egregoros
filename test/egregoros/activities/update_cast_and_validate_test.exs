defmodule Egregoros.Activities.UpdateCastAndValidateTest do
  use ExUnit.Case, async: true

  alias Egregoros.Activities.Update

  test "accepts Update for a Person when actor matches object id" do
    activity = %{
      "id" => "https://example.com/activities/update/1",
      "type" => "Update",
      "actor" => "https://example.com/users/alice",
      "object" => %{
        "id" => "https://example.com/users/alice",
        "type" => "Person"
      }
    }

    assert {:ok, validated} = Update.cast_and_validate(activity)
    assert validated["actor"] == "https://example.com/users/alice"
    assert validated["object"]["id"] == "https://example.com/users/alice"
  end

  test "rejects Update for a Person when actor does not match object id" do
    activity = %{
      "id" => "https://example.com/activities/update/1",
      "type" => "Update",
      "actor" => "https://example.com/users/alice",
      "object" => %{
        "id" => "https://example.com/users/bob",
        "type" => "Person"
      }
    }

    assert {:error, %Ecto.Changeset{}} = Update.cast_and_validate(activity)
  end
end

