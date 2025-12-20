defmodule PleromaRedux.Activities.CreateCastAndValidateTest do
  use ExUnit.Case, async: true

  alias PleromaRedux.Activities.Create
  alias PleromaRedux.TestSupport.PleromaOldFixtures

  test "normalizes an inline actor object id (kroeg fixture)" do
    activity = PleromaOldFixtures.json!("kroeg-post-activity.json")

    assert {:ok, validated} = Create.cast_and_validate(activity)
    assert validated["actor"] == activity["actor"]["id"]
    assert is_map(validated["object"])
    assert is_binary(validated["object"]["id"])
  end
end

