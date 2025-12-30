defmodule Egregoros.DNS.Cached do
  @moduledoc false

  @behaviour Egregoros.DNS

  @default_ttl_ms 60_000

  @impl true
  def lookup_ips(host) when is_binary(host) do
    opts = Application.get_env(:egregoros, __MODULE__, [])

    lookup_ips(host,
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      resolver: Keyword.get(opts, :resolver, Egregoros.DNS.Inet),
      table: Keyword.get(opts, :table, __MODULE__)
    )
  end

  def lookup_ips(host, opts) when is_binary(host) and is_list(opts) do
    resolver = Keyword.get(opts, :resolver, Egregoros.DNS.Inet)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    table = Keyword.get(opts, :table, __MODULE__)

    host =
      host
      |> String.trim()
      |> String.downcase()

    if host == "" do
      {:error, :nxdomain}
    else
      do_lookup_ips(host, resolver, ttl_ms, table)
    end
  end

  def lookup_ips(_host, _opts), do: {:error, :nxdomain}

  defp do_lookup_ips(host, resolver, ttl_ms, table)
       when is_binary(host) and is_integer(ttl_ms) do
    now_ms = System.monotonic_time(:millisecond)
    table = ensure_table(table)

    case :ets.lookup(table, host) do
      [{^host, expires_at_ms, ips}] when is_integer(expires_at_ms) and expires_at_ms > now_ms ->
        {:ok, ips}

      [{^host, _expires_at_ms, _ips}] ->
        _ = :ets.delete(table, host)
        resolve_and_cache(table, host, resolver, ttl_ms, now_ms)

      _ ->
        resolve_and_cache(table, host, resolver, ttl_ms, now_ms)
    end
  end

  defp ensure_table(table) when is_atom(table) do
    case :ets.whereis(table) do
      :undefined ->
        try do
          :ets.new(table, [
            :named_table,
            :set,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end

    table
  end

  defp ensure_table(table), do: table

  defp resolve_and_cache(table, host, resolver, ttl_ms, now_ms)
       when is_binary(host) and is_integer(ttl_ms) and is_integer(now_ms) do
    case resolver.lookup_ips(host) do
      {:ok, ips} = ok when is_list(ips) and ips != [] ->
        if ttl_ms > 0 do
          _ = :ets.insert(table, {host, now_ms + ttl_ms, ips})
        end

        ok

      other ->
        other
    end
  end
end

