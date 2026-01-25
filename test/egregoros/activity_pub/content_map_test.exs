defmodule Egregoros.ActivityPub.ContentMapTest do
  use ExUnit.Case, async: true

  alias Egregoros.ActivityPub.ContentMap

  test "normalize/1 prefers non-empty content over contentMap" do
    obj = %{"content" => "hi", "contentMap" => %{"en" => "hello"}}
    assert ContentMap.normalize(obj)["content"] == "hi"
  end

  test "normalize/1 fills content from contentMap when content is blank" do
    obj = %{"content" => "   ", "contentMap" => %{"en" => " hello "}}
    assert ContentMap.normalize(obj)["content"] == "hello"
  end

  test "normalize/1 falls back to first non-empty contentMap entry sorted by key" do
    obj = %{"contentMap" => %{"zz" => "z", "aa" => " a "}}
    assert ContentMap.normalize(obj)["content"] == "a"
  end
end
