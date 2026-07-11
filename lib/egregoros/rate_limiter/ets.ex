defmodule Egregoros.RateLimiter.ETS do
  @moduledoc """
  Atomic, fixed-window rate limits local to one Erlang node.

  In a multi-node deployment, configure `:rate_limit_node_count` to the
  maximum number of nodes that can receive traffic. The HTTP plug divides
  each deployment-wide limit across those nodes.
  """

  use GenServer

  @behaviour Egregoros.RateLimiter

  @table :egregoros_rate_limiter
  @cleanup_interval_ms 60_000
  @default_entry_ttl_ms 600_000

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    _ = ensure_table()
    schedule_cleanup()
    {:ok, %{entry_ttl_ms: entry_ttl_ms(opts)}}
  end

  @impl Egregoros.RateLimiter
  def allow?(bucket, key, limit, interval_ms)
      when is_atom(bucket) and is_binary(key) and is_integer(limit) and is_integer(interval_ms) do
    bucket = bucket
    key = key |> String.trim()

    cond do
      key == "" ->
        :ok

      limit < 1 ->
        :ok

      interval_ms < 1 ->
        :ok

      true ->
        now_ms = System.monotonic_time(:millisecond)
        window_id = Integer.floor_div(now_ms, interval_ms)
        ets_key = {bucket, key, interval_ms, window_id}
        new_count = bump_counter(ets_key, now_ms)

        if new_count <= limit do
          :ok
        else
          {:error, :rate_limited}
        end
    end
  end

  def allow?(_bucket, _key, _limit, _interval_ms), do: :ok

  @impl GenServer
  def handle_info(:cleanup, %{entry_ttl_ms: ttl_ms} = state) do
    now_ms = System.monotonic_time(:millisecond)
    threshold_ms = now_ms - ttl_ms
    _ = cleanup_old_entries(now_ms, threshold_ms)
    schedule_cleanup()
    {:noreply, state}
  end

  defp bump_counter(ets_key, now_ms) do
    count = :ets.update_counter(@table, ets_key, {2, 1}, {ets_key, 0, now_ms})
    _ = :ets.update_element(@table, ets_key, {3, now_ms})
    count
  end

  defp cleanup_old_entries(now_ms, threshold_ms)
       when is_integer(now_ms) and is_integer(threshold_ms) do
    match_spec = [
      {
        {{:"$1", :"$2", :"$3", :"$4"}, :"$5", :"$6"},
        [
          {:andalso, {:<, :"$6", threshold_ms}, {:"=<", {:*, {:+, :"$4", 1}, :"$3"}, now_ms}}
        ],
        [true]
      }
    ]

    :ets.select_delete(@table, match_spec)
  end

  defp entry_ttl_ms(opts) when is_list(opts) do
    case Keyword.get(opts, :entry_ttl_ms, @default_entry_ttl_ms) do
      ttl when is_integer(ttl) and ttl >= 0 -> ttl
      _ -> @default_entry_ttl_ms
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _tid ->
        @table
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
