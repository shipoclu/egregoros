defmodule Egregoros.Activities.AcceptCastAndValidateTest do
  use ExUnit.Case, async: true

  alias Egregoros.Activities.Accept
  alias Egregoros.TestSupport.Fixtures

  test "accepts an embedded Follow object (mastodon fixture)" do
    activity = Fixtures.json!("mastodon-accept-activity.json")

    assert {:ok, validated} = Accept.cast_and_validate(activity)
    assert validated["actor"] == activity["actor"]
    assert is_map(validated["object"])
    assert validated["object"]["id"] == activity["object"]["id"]
  end
end
