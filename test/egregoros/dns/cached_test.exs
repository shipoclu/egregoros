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

  test "never creates a caller-owned public named table when the cache owner is absent" do
    table = :egregoros_dns_cache_absent_test
    assert :ets.whereis(table) == :undefined

    expect(Egregoros.DNS.Mock, :lookup_ips, fn "example.com" ->
      {:ok, [{1, 1, 1, 1}]}
    end)

    assert {:ok, [{1, 1, 1, 1}]} =
             Cached.lookup_ips("example.com",
               resolver: Egregoros.DNS.Mock,
               ttl_ms: 60_000,
               table: table,
               cache_server: nil
             )

    assert :ets.whereis(table) == :undefined
  end

  test "fails closed before DNS when a required cache owner is unavailable" do
    cache = {:global, {__MODULE__, make_ref()}}

    expect(Egregoros.DNS.Mock, :lookup_ips, 0, fn _host ->
      flunk("DNS must not run without the required supervised cache boundary")
    end)

    assert {:error, :dns_cache_unavailable} =
             Cached.lookup_ips("example.com",
               resolver: Egregoros.DNS.Mock,
               ttl_ms: 60_000,
               table: :egregoros_dns_cache_absent_test,
               cache_server: cache
             )
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

  test "bounds the number of cached hostnames even when every lookup is unique" do
    cache = {:global, {__MODULE__, make_ref()}}

    start_supervised!(
      {Cached, name: cache, table: :unnamed, max_entries: 5, cleanup_interval_ms: 60_000}
    )

    table = Cached.table(cache)

    expect(Egregoros.DNS.Mock, :lookup_ips, 20, fn host ->
      octet = host |> String.split(".") |> hd() |> String.to_integer()
      {:ok, [{8, 8, 8, octet}]}
    end)

    opts = [
      resolver: Egregoros.DNS.Mock,
      ttl_ms: 60_000,
      table: table,
      cache_server: cache
    ]

    for octet <- 1..20 do
      assert {:ok, [{8, 8, 8, ^octet}]} = Cached.lookup_ips("#{octet}.example", opts)
      assert :ets.info(table, :size) <= 5
    end

    assert :ets.info(table, :size) == 5
  end

  test "the periodic sweep removes expired hostnames that are never looked up again" do
    cache = {:global, {__MODULE__, make_ref()}}

    pid =
      start_supervised!(
        {Cached, name: cache, table: :unnamed, max_entries: 100, cleanup_interval_ms: 60_000}
      )

    table = Cached.table(cache)
    now_ms = System.monotonic_time(:millisecond)

    :sys.replace_state(pid, fn state ->
      for number <- 1..50 do
        :ets.insert(table, {"expired-#{number}.example", now_ms - 1, [{8, 8, 8, 8}]})
      end

      state
    end)

    first_timer_ref = :sys.get_state(pid).cleanup_timer_ref
    assert is_reference(first_timer_ref)
    send(pid, :cleanup)
    state = :sys.get_state(pid)

    assert :ets.info(table, :size) == 0
    assert is_reference(state.cleanup_timer_ref)
    refute state.cleanup_timer_ref == first_timer_ref
  end
end
