defmodule Egregoros.DNS.Cached do
  @moduledoc false

  use GenServer

  @behaviour Egregoros.DNS

  @default_ttl_ms 60_000
  @default_max_entries 4_096
  @default_cleanup_interval_ms 60_000
  @hard_max_entries 16_384
  @hard_max_cleanup_interval_ms 60_000
  @default_table :egregoros_dns_cache

  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def table(server \\ __MODULE__), do: GenServer.call(server, :table)

  def cleanup(server \\ __MODULE__), do: GenServer.call(server, :cleanup)

  @impl GenServer
  def init(opts) do
    configured = Egregoros.Config.get(__MODULE__, [])

    max_entries =
      opts
      |> Keyword.get(:max_entries, Keyword.get(configured, :max_entries, @default_max_entries))
      |> bounded_integer(@default_max_entries, 1..@hard_max_entries)

    cleanup_interval_ms =
      opts
      |> Keyword.get(
        :cleanup_interval_ms,
        Keyword.get(configured, :cleanup_interval_ms, @default_cleanup_interval_ms)
      )
      |> bounded_integer(
        @default_cleanup_interval_ms,
        1_000..@hard_max_cleanup_interval_ms
      )

    table =
      opts
      |> Keyword.get(:table, Keyword.get(configured, :table, @default_table))
      |> create_owned_table()

    state = %{
      table: table,
      max_entries: max_entries,
      cleanup_interval_ms: cleanup_interval_ms,
      cleanup_timer_ref: nil
    }

    {:ok, schedule_cleanup(state)}
  end

  @impl GenServer
  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  def handle_call(:cleanup, _from, state) do
    state = cleanup_table(state)
    {:reply, :ok, state}
  end

  def handle_call({:cache, host, expires_at_ms, ips}, _from, state) do
    cache_insert(state.table, host, expires_at_ms, ips, state.max_entries)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    state =
      state
      |> cleanup_table()
      |> schedule_cleanup()

    {:noreply, state}
  end

  @impl true
  def lookup_ips(host) when is_binary(host) do
    opts = Egregoros.Config.get(__MODULE__, [])

    lookup_ips(host,
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      resolver: Keyword.get(opts, :resolver, Egregoros.DNS.Inet),
      table: Keyword.get(opts, :table, @default_table),
      max_entries: Keyword.get(opts, :max_entries, @default_max_entries),
      cache_server: __MODULE__
    )
  end

  def lookup_ips(host, opts) when is_binary(host) and is_list(opts) do
    resolver = Keyword.get(opts, :resolver, Egregoros.DNS.Inet)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    table = Keyword.get(opts, :table, @default_table)
    cache_server = Keyword.get(opts, :cache_server)

    max_entries =
      opts
      |> Keyword.get(:max_entries, @default_max_entries)
      |> bounded_integer(@default_max_entries, 1..@hard_max_entries)

    host =
      host
      |> String.trim()
      |> String.downcase()

    if host == "" do
      {:error, :nxdomain}
    else
      with {:ok, table} <- cache_table(table, cache_server) do
        do_lookup_ips(host, resolver, ttl_ms, table, cache_server, max_entries)
      end
    end
  end

  def lookup_ips(_host, _opts), do: {:error, :nxdomain}

  defp do_lookup_ips(host, resolver, ttl_ms, table, cache_server, max_entries)
       when is_binary(host) and is_integer(ttl_ms) do
    now_ms = System.monotonic_time(:millisecond)
    table = ensure_table(table)

    case cache_lookup(table, host) do
      [{^host, expires_at_ms, ips}] when is_integer(expires_at_ms) and expires_at_ms > now_ms ->
        {:ok, ips}

      [{^host, _expires_at_ms, _ips}] ->
        resolve_and_cache(
          table,
          host,
          resolver,
          ttl_ms,
          now_ms,
          cache_server,
          max_entries
        )

      _ ->
        resolve_and_cache(
          table,
          host,
          resolver,
          ttl_ms,
          now_ms,
          cache_server,
          max_entries
        )
    end
  end

  # Named production tables are created only by the supervised cache owner.
  # A request racing an owner restart may resolve without caching, but it must
  # never create a public, request-owned table that other processes can poison.
  defp ensure_table(table) when is_atom(table), do: table

  defp ensure_table(table), do: table

  defp cache_table(table, nil), do: {:ok, ensure_table(table)}

  defp cache_table(_table, cache_server) do
    owner = GenServer.whereis(cache_server)
    table = GenServer.call(cache_server, :table)

    if is_pid(owner) and :ets.info(table, :owner) == owner and
         :ets.info(table, :protection) == :protected do
      {:ok, table}
    else
      {:error, :dns_cache_unavailable}
    end
  rescue
    ArgumentError -> {:error, :dns_cache_unavailable}
  catch
    :exit, _reason -> {:error, :dns_cache_unavailable}
  end

  defp cache_lookup(table, host) do
    :ets.lookup(table, host)
  rescue
    ArgumentError -> []
  end

  defp resolve_and_cache(
         table,
         host,
         resolver,
         ttl_ms,
         now_ms,
         cache_server,
         max_entries
       )
       when is_binary(host) and is_integer(ttl_ms) and is_integer(now_ms) do
    case resolver.lookup_ips(host) do
      {:ok, ips} = ok when is_list(ips) and ips != [] ->
        if ttl_ms > 0 do
          case put_cache(cache_server, table, host, now_ms + ttl_ms, ips, max_entries) do
            :ok -> ok
            {:error, _reason} = error -> error
          end
        else
          ok
        end

      other ->
        other
    end
  end

  defp put_cache(nil, table, host, expires_at_ms, ips, max_entries) do
    cache_insert(table, host, expires_at_ms, ips, max_entries)
  end

  defp put_cache(cache_server, _table, host, expires_at_ms, ips, _max_entries) do
    GenServer.call(cache_server, {:cache, host, expires_at_ms, ips})
  catch
    :exit, _reason -> {:error, :dns_cache_unavailable}
  end

  defp cache_insert(table, host, expires_at_ms, ips, max_entries) do
    if :ets.lookup(table, host) == [] do
      trim_to_size(table, max_entries - 1)
    end

    _ = :ets.insert(table, {host, expires_at_ms, ips})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp cleanup_table(state) do
    prune_expired(state.table, System.monotonic_time(:millisecond))
    trim_to_size(state.table, state.max_entries)
    state
  end

  defp prune_expired(table, now_ms) do
    expired_hosts =
      :ets.foldl(
        fn
          {host, expires_at_ms, _ips}, hosts
          when is_integer(expires_at_ms) and expires_at_ms <= now_ms ->
            [host | hosts]

          _entry, hosts ->
            hosts
        end,
        [],
        table
      )

    Enum.each(expired_hosts, &:ets.delete(table, &1))
    :ok
  end

  defp trim_to_size(table, max_entries) when is_integer(max_entries) and max_entries >= 0 do
    excess = max(:ets.info(table, :size) - max_entries, 0)
    delete_entries(table, :ets.first(table), excess)
  end

  defp delete_entries(_table, _key, 0), do: :ok
  defp delete_entries(_table, :"$end_of_table", _count), do: :ok

  defp delete_entries(table, key, count) do
    next_key = :ets.next(table, key)
    _ = :ets.delete(table, key)
    delete_entries(table, next_key, count - 1)
  end

  defp create_owned_table(:unnamed) do
    :ets.new(__MODULE__, [
      :set,
      :protected,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  defp create_owned_table(table) when is_atom(table) do
    :ets.new(table, [
      :named_table,
      :set,
      :protected,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  defp schedule_cleanup(state) do
    if is_reference(state.cleanup_timer_ref) do
      _ = Process.cancel_timer(state.cleanup_timer_ref)
    end

    timer_ref = Process.send_after(self(), :cleanup, state.cleanup_interval_ms)
    %{state | cleanup_timer_ref: timer_ref}
  end

  defp bounded_integer(value, default, range) do
    if is_integer(value) and value in range, do: value, else: default
  end
end
