defmodule PleromaRedux.Activities.CreateCastAndValidateTest do
  use ExUnit.Case, async: true

  alias PleromaRedux.Activities.Create
  alias PleromaRedux.TestSupport.Fixtures

  test "normalizes an inline actor object id (kroeg fixture)" do
    activity = Fixtures.json!("kroeg-post-activity.json")

    assert {:ok, validated} = Create.cast_and_validate(activity)
    assert validated["actor"] == activity["actor"]["id"]
    assert is_map(validated["object"])
    assert is_binary(validated["object"]["id"])
  end

  test "rejects Create when embedded object actor does not match Create actor" do
    activity = %{
      "id" => "https://example.com/activities/create/1",
      "type" => "Create",
      "actor" => "https://example.com/users/alice",
      "object" => %{
        "id" => "https://example.com/objects/1",
        "type" => "Note",
        "attributedTo" => "https://example.com/users/bob",
        "content" => "Hello"
      }
    }

    assert {:error, %Ecto.Changeset{}} = Create.cast_and_validate(activity)
  end
end
