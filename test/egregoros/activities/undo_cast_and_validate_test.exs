defmodule Egregoros.Activities.UndoCastAndValidateTest do
  use ExUnit.Case, async: true

  alias Egregoros.Activities.Undo
  alias Egregoros.TestSupport.Fixtures

  test "normalizes an embedded Like object into its id (mastodon fixture)" do
    activity = Fixtures.json!("mastodon-undo-like.json")

    assert {:ok, validated} = Undo.cast_and_validate(activity)
    assert is_binary(validated["object"])
    assert validated["object"] == activity["object"]["id"]
  end
end
