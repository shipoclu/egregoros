defmodule PleromaReduxWeb.TimeTest do
  use ExUnit.Case, async: true

  alias PleromaReduxWeb.Time

  describe "relative/2" do
    test "formats seconds, minutes, hours, days, weeks, and years" do
      now = ~U[2025-01-01 00:00:00Z]

      assert Time.relative(~U[2025-01-01 00:00:00Z], now) == "now"
      assert Time.relative(~U[2024-12-31 23:59:50Z], now) == "10s"
      assert Time.relative(~U[2024-12-31 23:58:59Z], now) == "1m"
      assert Time.relative(~U[2024-12-31 23:00:00Z], now) == "1h"
      assert Time.relative(~U[2024-12-30 00:00:00Z], now) == "2d"
      assert Time.relative(~U[2024-12-10 00:00:00Z], now) == "3w"
      assert Time.relative(~U[2023-01-01 00:00:00Z], now) == "2y"
    end

    test "treats naive datetimes as UTC" do
      now = ~U[2025-01-01 00:00:00Z]
      assert Time.relative(~N[2024-12-31 23:59:00], now) == "1m"
    end
  end
end
