defmodule Egregoros.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Egregoros.RateLimiter

  test "allow?/4 returns :ok for invalid arguments" do
    assert :ok = RateLimiter.allow?("bucket", :not_a_binary, 10, 1_000)
  end
end
