defmodule Egregoros.DNS.CachedTest do
  use ExUnit.Case, async: true

  import Mox

  alias Egregoros.DNS.Cached

  setup :set_mox_from_context
  setup :verify_on_exit!

  test "caches successful lookups until the TTL expires" do
    table = :ets.new(:dns_cached_test, [:set, :public])

    try do
      expect(Egregoros.DNS.Mock, :lookup_ips, fn "example.com" ->
        {:ok, [{1, 1, 1, 1}]}
      end)

      opts = [resolver: Egregoros.DNS.Mock, ttl_ms: 60_000, table: table]

      assert {:ok, [{1, 1, 1, 1}]} = Cached.lookup_ips("example.com", opts)

      # should hit the cache (normalized host) and not call the resolver again
      assert {:ok, [{1, 1, 1, 1}]} = Cached.lookup_ips("  EXAMPLE.COM  ", opts)
    after
      :ets.delete(table)
    end
  end

  test "does not cache results when ttl_ms is 0" do
    table = :ets.new(:dns_cached_test, [:set, :public])

    try do
      expect(Egregoros.DNS.Mock, :lookup_ips, 2, fn "example.com" ->
        {:ok, [{1, 1, 1, 1}]}
      end)

      opts = [resolver: Egregoros.DNS.Mock, ttl_ms: 0, table: table]

      assert {:ok, [{1, 1, 1, 1}]} = Cached.lookup_ips("example.com", opts)
      assert {:ok, [{1, 1, 1, 1}]} = Cached.lookup_ips("example.com", opts)
    after
      :ets.delete(table)
    end
  end

  test "evicts expired cache entries and re-resolves" do
    table = :ets.new(:dns_cached_test, [:set, :public])

    try do
      now_ms = System.monotonic_time(:millisecond)
      :ets.insert(table, {"example.com", now_ms - 1, [{9, 9, 9, 9}]})

      expect(Egregoros.DNS.Mock, :lookup_ips, fn "example.com" ->
        {:ok, [{1, 1, 1, 1}]}
      end)

      opts = [resolver: Egregoros.DNS.Mock, ttl_ms: 60_000, table: table]

      assert {:ok, [{1, 1, 1, 1}]} = Cached.lookup_ips("example.com", opts)
      assert [{"example.com", _expires_at_ms, [{1, 1, 1, 1}]}] = :ets.lookup(table, "example.com")
    after
      :ets.delete(table)
    end
  end

  test "does not cache empty results and passes through resolver errors" do
    table = :ets.new(:dns_cached_test, [:set, :public])

    try do
      expect(Egregoros.DNS.Mock, :lookup_ips, fn "example.com" ->
        {:ok, []}
      end)

      opts = [resolver: Egregoros.DNS.Mock, ttl_ms: 60_000, table: table]

      assert {:ok, []} = Cached.lookup_ips("example.com", opts)
      assert [] = :ets.lookup(table, "example.com")

      expect(Egregoros.DNS.Mock, :lookup_ips, fn "example.com" ->
        {:error, :nxdomain}
      end)

      assert {:error, :nxdomain} = Cached.lookup_ips("example.com", opts)
      assert [] = :ets.lookup(table, "example.com")
    after
      :ets.delete(table)
    end
  end

  test "returns nxdomain for blank or invalid hosts" do
    table = :ets.new(:dns_cached_test, [:set, :public])

    try do
      opts = [resolver: Egregoros.DNS.Mock, ttl_ms: 60_000, table: table]

      assert {:error, :nxdomain} = Cached.lookup_ips("   ", opts)
      assert {:error, :nxdomain} = Cached.lookup_ips(nil, opts)
    after
      :ets.delete(table)
    end
  end
end
