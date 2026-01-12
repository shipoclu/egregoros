defmodule EgregorosWeb.MastodonAPI.FallbackTest do
  use ExUnit.Case, async: true

  alias EgregorosWeb.MastodonAPI.Fallback

  test "fallback_username/1 extracts last path segment" do
    assert Fallback.fallback_username("https://example.com/users/alice") == "alice"
    assert Fallback.fallback_username("https://example.com/@bob") == "@bob"
  end

  test "fallback_username/1 returns unknown when it cannot determine a username" do
    assert Fallback.fallback_username("https://example.com") == "unknown"
    assert Fallback.fallback_username(nil) == "unknown"
  end
end
