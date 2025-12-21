defmodule PleromaRedux.Activities.FollowCastAndValidateTest do
  use ExUnit.Case, async: true

  alias PleromaRedux.Activities.Follow
  alias PleromaRedux.TestSupport.Fixtures

  test "normalizes an inline actor object id (hubzilla fixture)" do
    activity = Fixtures.json!("hubzilla-follow-activity.json")

    assert {:ok, validated} = Follow.cast_and_validate(activity)
    assert validated["actor"] == activity["actor"]["id"]
    assert validated["object"] == activity["object"]
  end
end
