defmodule Egregoros.HTTPDateTest do
  use ExUnit.Case, async: true

  alias Egregoros.HTTPDate

  describe "parse_rfc1123/1" do
    test "parses IMF-fixdate values" do
      assert {:ok, dt} = HTTPDate.parse_rfc1123("Thu, 08 Jan 2026 15:58:21 GMT")
      assert dt.year == 2026
      assert dt.month == 1
      assert dt.day == 8
      assert dt.hour == 15
      assert dt.minute == 58
      assert dt.second == 21
      assert dt.time_zone == "Etc/UTC"
    end

    test "returns invalid_date for bad values" do
      assert {:error, :invalid_date} = HTTPDate.parse_rfc1123("definitely-not-a-date")
      assert {:error, :invalid_date} = HTTPDate.parse_rfc1123("Thu, 99 Jan 2026 15:58:21 GMT")
      assert {:error, :invalid_date} = HTTPDate.parse_rfc1123("Thu, 08 Foo 2026 15:58:21 GMT")
    end
  end

  describe "format_rfc1123/1" do
    test "formats IMF-fixdate values" do
      dt = DateTime.from_naive!(~N[2026-01-08 15:58:21], "Etc/UTC")
      assert HTTPDate.format_rfc1123(dt) == "Thu, 08 Jan 2026 15:58:21 GMT"
    end

    test "round-trips with parse_rfc1123/1 (second precision)" do
      dt = DateTime.utc_now() |> DateTime.truncate(:second)
      assert {:ok, parsed} = HTTPDate.parse_rfc1123(HTTPDate.format_rfc1123(dt))
      assert DateTime.compare(parsed, dt) == :eq
    end
  end
end
