defmodule Egregoros.DNS.CachedTest do
  use ExUnit.Case, async: true

  defmodule Resolver do
    @behaviour Egregoros.DNS

    @impl true
    def lookup_ips(host) when is_binary(host) do
      send(Process.get(:dns_test_pid), {:lookup, host})
      {:ok, [{1, 1, 1, 1}]}
    end
  end

  test "caches lookups within TTL" do
    Process.put(:dns_test_pid, self())
    table = :ets.new(:dns_cache_test, [:set, :public])

    try do
      assert {:ok, [{1, 1, 1, 1}]} =
               Egregoros.DNS.Cached.lookup_ips("example.com",
                 resolver: Resolver,
                 ttl_ms: 60_000,
                 table: table
               )

      assert_receive {:lookup, "example.com"}

      assert {:ok, [{1, 1, 1, 1}]} =
               Egregoros.DNS.Cached.lookup_ips("example.com",
                 resolver: Resolver,
                 ttl_ms: 60_000,
                 table: table
               )

      refute_receive {:lookup, _host}
    after
      :ets.delete(table)
    end
  end

  test "does not cache when ttl is 0" do
    Process.put(:dns_test_pid, self())
    table = :ets.new(:dns_cache_test, [:set, :public])

    try do
      assert {:ok, [{1, 1, 1, 1}]} =
               Egregoros.DNS.Cached.lookup_ips("example.com",
                 resolver: Resolver,
                 ttl_ms: 0,
                 table: table
               )

      assert_receive {:lookup, "example.com"}

      assert {:ok, [{1, 1, 1, 1}]} =
               Egregoros.DNS.Cached.lookup_ips("example.com",
                 resolver: Resolver,
                 ttl_ms: 0,
                 table: table
               )

      assert_receive {:lookup, "example.com"}
    after
      :ets.delete(table)
    end
  end
end
