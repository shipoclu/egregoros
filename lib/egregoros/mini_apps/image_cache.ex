defmodule Egregoros.MiniApps.ImageCache do
  @moduledoc false

  use GenServer

  alias Egregoros.Config

  @default_ttl_ms 300_000
  @default_max_entries 512
  @default_max_bytes 64 * 1_024 * 1_024
  @default_cleanup_interval_ms 60_000
  @default_call_timeout_ms 15_000
  @hard_max_ttl_ms 3_600_000
  @hard_max_entries 4_096
  @hard_max_bytes 256 * 1_024 * 1_024
  @hard_max_cleanup_interval_ms 60_000

  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def fetch(key, loader, opts \\ []) when is_function(loader, 0) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @default_call_timeout_ms)

    case cache_call(server, {:acquire, key}, timeout) do
      {:ok, {:hit, result}} ->
        result

      {:ok, :load} ->
        load_and_complete(server, key, loader, timeout)

      {:ok, {:result, result}} ->
        result

      {:error, :cache_unavailable} ->
        safely_load(loader)
    end
  end

  def clear(server \\ __MODULE__) do
    case cache_call(server, :clear, @default_call_timeout_ms) do
      {:ok, :ok} -> :ok
      {:error, :cache_unavailable} -> {:error, :cache_unavailable}
    end
  end

  @impl GenServer
  def init(opts) do
    configured = Config.get(__MODULE__, [])

    ttl_ms =
      opts
      |> Keyword.get(:ttl_ms, Keyword.get(configured, :ttl_ms, @default_ttl_ms))
      |> bounded_integer(@default_ttl_ms, 1_000..@hard_max_ttl_ms)

    max_entries =
      opts
      |> Keyword.get(
        :max_entries,
        Keyword.get(configured, :max_entries, @default_max_entries)
      )
      |> bounded_integer(@default_max_entries, 1..@hard_max_entries)

    max_bytes =
      opts
      |> Keyword.get(:max_bytes, Keyword.get(configured, :max_bytes, @default_max_bytes))
      |> bounded_integer(@default_max_bytes, 1..@hard_max_bytes)

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

    state = %{
      entries: %{},
      in_flight: %{},
      monitors: %{},
      total_bytes: 0,
      sequence: 0,
      ttl_ms: ttl_ms,
      max_entries: max_entries,
      max_bytes: max_bytes,
      cleanup_interval_ms: cleanup_interval_ms,
      cleanup_timer_ref: nil
    }

    {:ok, schedule_cleanup(state)}
  end

  @impl GenServer
  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | entries: %{}, total_bytes: 0}}
  end

  def handle_call({:acquire, key}, from, state) do
    now_ms = System.monotonic_time(:millisecond)
    state = prune_expired(state, now_ms)

    case Map.fetch(state.entries, key) do
      {:ok, entry} ->
        state = touch_entry(state, key, entry)
        {:reply, {:hit, entry.result}, state}

      :error ->
        acquire_miss(key, from, state)
    end
  end

  def handle_call({:complete, key, owner, result}, _from, state) do
    case Map.get(state.in_flight, key) do
      %{owner: ^owner, monitor_ref: monitor_ref, waiters: waiters} ->
        Process.demonitor(monitor_ref, [:flush])
        Enum.each(waiters, &GenServer.reply(&1, {:result, result}))

        state =
          state
          |> remove_in_flight(key, monitor_ref)
          |> maybe_store(key, result)

        {:reply, :ok, state}

      _flight ->
        {:reply, {:error, :not_loader}, state}
    end
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    state =
      state
      |> prune_expired(System.monotonic_time(:millisecond))
      |> schedule_cleanup()

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {key, monitors} ->
        case Map.pop(state.in_flight, key) do
          {nil, _in_flight} ->
            {:noreply, %{state | monitors: monitors}}

          {%{waiters: waiters}, in_flight} ->
            result = {:error, {:cache, :loader_down}}
            Enum.each(waiters, &GenServer.reply(&1, {:result, result}))
            {:noreply, %{state | in_flight: in_flight, monitors: monitors}}
        end
    end
  end

  defp acquire_miss(key, from, state) do
    case Map.get(state.in_flight, key) do
      nil ->
        owner = elem(from, 0)
        monitor_ref = Process.monitor(owner)
        flight = %{owner: owner, monitor_ref: monitor_ref, waiters: []}

        state = %{
          state
          | in_flight: Map.put(state.in_flight, key, flight),
            monitors: Map.put(state.monitors, monitor_ref, key)
        }

        {:reply, :load, state}

      flight ->
        in_flight = Map.put(state.in_flight, key, %{flight | waiters: [from | flight.waiters]})
        {:noreply, %{state | in_flight: in_flight}}
    end
  end

  defp load_and_complete(server, key, loader, timeout) do
    result = safely_load(loader)

    _ = cache_call(server, {:complete, key, self(), result}, timeout)
    result
  end

  defp safely_load(loader) do
    loader.()
  rescue
    error -> {:error, {:cache, {:loader_exception, error.__struct__, Exception.message(error)}}}
  catch
    kind, reason -> {:error, {:cache, {:loader_catch, kind, reason}}}
  end

  defp cache_call(server, message, timeout) do
    {:ok, GenServer.call(server, message, timeout)}
  catch
    :exit, _reason -> {:error, :cache_unavailable}
  end

  defp maybe_store(state, key, {:ok, %{body: body, content_type: content_type}} = result)
       when is_binary(body) and is_binary(content_type) do
    body_bytes = byte_size(body)

    if body_bytes <= state.max_bytes do
      state =
        state
        |> drop_entry(key)
        |> make_room(body_bytes)

      sequence = state.sequence + 1

      entry = %{
        result: result,
        body_bytes: body_bytes,
        expires_at_ms: System.monotonic_time(:millisecond) + state.ttl_ms,
        sequence: sequence
      }

      %{
        state
        | entries: Map.put(state.entries, key, entry),
          total_bytes: state.total_bytes + body_bytes,
          sequence: sequence
      }
    else
      state
    end
  end

  defp maybe_store(state, _key, _result), do: state

  defp make_room(state, incoming_bytes) do
    if map_size(state.entries) >= state.max_entries or
         state.total_bytes + incoming_bytes > state.max_bytes do
      state
      |> evict_oldest()
      |> make_room(incoming_bytes)
    else
      state
    end
  end

  defp evict_oldest(%{entries: entries} = state) when map_size(entries) == 0, do: state

  defp evict_oldest(state) do
    {key, _entry} = Enum.min_by(state.entries, fn {_key, entry} -> entry.sequence end)
    drop_entry(state, key)
  end

  defp touch_entry(state, key, entry) do
    sequence = state.sequence + 1

    %{
      state
      | entries: Map.put(state.entries, key, %{entry | sequence: sequence}),
        sequence: sequence
    }
  end

  defp prune_expired(state, now_ms) do
    Enum.reduce(state.entries, state, fn {key, entry}, acc ->
      if entry.expires_at_ms <= now_ms, do: drop_entry(acc, key), else: acc
    end)
  end

  defp drop_entry(state, key) do
    case Map.pop(state.entries, key) do
      {nil, _entries} ->
        state

      {entry, entries} ->
        %{state | entries: entries, total_bytes: state.total_bytes - entry.body_bytes}
    end
  end

  defp remove_in_flight(state, key, monitor_ref) do
    %{
      state
      | in_flight: Map.delete(state.in_flight, key),
        monitors: Map.delete(state.monitors, monitor_ref)
    }
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
