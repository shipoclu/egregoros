defmodule Egregoros.Activities.HelpersTest do
  use ExUnit.Case, async: true

  alias Egregoros.Activities.Helpers

  describe "maybe_put/3" do
    test "keeps maps unchanged when the value is nil" do
      assert Helpers.maybe_put(%{a: 1}, :b, nil) == %{a: 1}
      assert Helpers.maybe_put(%{"a" => 1}, "b", nil) == %{"a" => 1}
    end

    test "puts values into maps when present" do
      assert Helpers.maybe_put(%{a: 1}, :b, 2) == %{a: 1, b: 2}
      assert Helpers.maybe_put(%{"a" => 1}, "b", "2") == %{"a" => 1, "b" => "2"}
    end
  end

  describe "parse_datetime/1" do
    test "returns nil for nil input" do
      assert Helpers.parse_datetime(nil) == nil
    end

    test "passes through DateTime structs" do
      now = DateTime.utc_now()
      assert Helpers.parse_datetime(now) == now
    end

    test "parses valid ISO8601 strings and returns nil for invalid inputs" do
      assert %DateTime{} = Helpers.parse_datetime("2025-12-31T23:59:59Z")
      assert Helpers.parse_datetime("not-a-date") == nil
      assert Helpers.parse_datetime(123) == nil
    end
  end
end
