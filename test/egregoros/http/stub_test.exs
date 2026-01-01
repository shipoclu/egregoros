defmodule Egregoros.HTTP.StubTest do
  use ExUnit.Case, async: true

  test "get/2 returns an empty json body" do
    assert {:ok, %{status: 200, body: %{}, headers: []}} =
             Egregoros.HTTP.Stub.get("https://example.com", [{"accept", "application/json"}])
  end

  test "post/3 returns accepted with an empty body" do
    assert {:ok, %{status: 202, body: "", headers: []}} =
             Egregoros.HTTP.Stub.post("https://example.com/inbox", "{}", [])
  end
end
