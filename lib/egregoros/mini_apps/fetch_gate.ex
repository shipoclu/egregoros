defmodule Egregoros.MiniApps.FetchGate do
  @moduledoc """
  Bounds untrusted mini-app network work before DNS or sockets are touched.

  The gate applies independent instance and exact-origin concurrency ceilings,
  a bounded waiting queue, and sliding-window request rates. A caller owns its
  permit: if it exits, the monitor releases the slot without relying on caller
  cleanup code.
  """

  use GenServer

  @default_max_global 12
  @default_max_per_origin 2
  @default_max_queue 64
  @default_queue_timeout_ms 2_000
  @default_global_rate_limit 300
  @default_origin_rate_limit 30
  @default_rate_interval_ms 60_000

  @hard_max_global 32
  @hard_max_per_origin 4
  @hard_max_queue 256
  @hard_max_queue_timeout_ms 5_000
  @hard_max_global_rate_limit 2_000
  @hard_max_origin_rate_limit 120
  @max_origin_bytes 256

  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def run(origin, fun, opts \\ [])

  def run(origin, fun, opts)
      when is_binary(origin) and is_function(fun, 0) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)

    with :ok <- validate_origin_key(origin),
         {:ok, token} <- acquire(server, origin) do
      try do
        {:ok, fun.()}
      after
        GenServer.cast(server, {:release, token})
      end
    end
  end

  def run(_origin, _fun, _opts), do: {:error, :invalid_fetch_origin}

  @impl GenServer
  def init(opts) do
    limits = %{
      max_global:
        limit(
          opts,
          :max_global,
          :mini_app_fetch_max_global,
          @default_max_global,
          1..@hard_max_global
        ),
      max_per_origin:
        limit(
          opts,
          :max_per_origin,
          :mini_app_fetch_max_per_origin,
          @default_max_per_origin,
          1..@hard_max_per_origin
        ),
      max_queue:
        limit(opts, :max_queue, :mini_app_fetch_max_queue, @default_max_queue, 0..@hard_max_queue),
      queue_timeout_ms:
        limit(
          opts,
          :queue_timeout_ms,
          :mini_app_fetch_queue_timeout_ms,
          @default_queue_timeout_ms,
          1..@hard_max_queue_timeout_ms
        ),
      global_rate_limit:
        limit(
          opts,
          :global_rate_limit,
          :mini_app_fetch_global_rate_limit,
          @default_global_rate_limit,
          1..@hard_max_global_rate_limit
        ),
      origin_rate_limit:
        limit(
          opts,
          :origin_rate_limit,
          :mini_app_fetch_origin_rate_limit,
          @default_origin_rate_limit,
          1..@hard_max_origin_rate_limit
        ),
      rate_interval_ms:
        limit(
          opts,
          :rate_interval_ms,
          :mini_app_fetch_rate_interval_ms,
          @default_rate_interval_ms,
          1_000..60_000
        )
    }

    {:ok,
     %{
       limits: limits,
       active: %{},
       active_by_origin: %{},
       queue: :queue.new(),
       queued_count: 0,
       global_events: [],
       origin_events: %{}
     }}
  end

  @impl GenServer
  def handle_call({:acquire, origin}, from, state) do
    now = System.monotonic_time(:millisecond)
    {rate_result, state} = admit_rate(state, origin, now)

    case rate_result do
      :ok ->
        cond do
          slot_available?(state, origin) ->
            {token, state} = activate(state, origin, from)
            {:reply, {:ok, token}, state}

          state.queued_count < state.limits.max_queue ->
            {:noreply, enqueue(state, origin, from)}

          true ->
            {:reply, {:error, :fetch_queue_full}, state}
        end

      {:error, :fetch_rate_limited} = error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_cast({:release, token}, state) do
    {:noreply, state |> release(token) |> dispatch_queue()}
  end

  @impl GenServer
  def handle_info({:queue_timeout, monitor_ref}, state) do
    {entry, state} = remove_queued(state, monitor_ref)

    if entry do
      Process.demonitor(entry.monitor_ref, [:flush])
      GenServer.reply(entry.from, {:error, :fetch_queue_timeout})
    end

    {:noreply, dispatch_queue(state)}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    state =
      case find_active_token(state, monitor_ref) do
        nil ->
          {_entry, state} = remove_queued(state, monitor_ref)
          state

        token ->
          release(state, token, demonitor: false)
      end

    {:noreply, dispatch_queue(state)}
  end

  defp acquire(server, origin) do
    # The gate owns the bounded queue timeout. A shorter client-side call
    # timeout could return to a still-live caller before the server processes
    # its acquire request, allowing a late reply to create an orphan permit.
    GenServer.call(server, {:acquire, origin}, :infinity)
  catch
    :exit, _reason -> {:error, :fetch_gate_unavailable}
  end

  defp validate_origin_key(origin) do
    if origin != "" and byte_size(origin) <= @max_origin_bytes and String.valid?(origin),
      do: :ok,
      else: {:error, :invalid_fetch_origin}
  end

  defp limit(opts, option, env_key, default, range) do
    configured = Keyword.get(opts, option, Application.get_env(:egregoros, env_key, default))
    if is_integer(configured) and configured in range, do: configured, else: default
  end

  defp admit_rate(state, origin, now) do
    threshold = now - state.limits.rate_interval_ms
    global_events = Enum.filter(state.global_events, &(&1 > threshold))

    all_origin_events =
      Enum.reduce(state.origin_events, %{}, fn {event_origin, events}, acc ->
        case Enum.filter(events, &(&1 > threshold)) do
          [] -> acc
          current -> Map.put(acc, event_origin, current)
        end
      end)

    origin_events = Map.get(all_origin_events, origin, [])

    state = %{
      state
      | global_events: global_events,
        origin_events: all_origin_events
    }

    if length(global_events) >= state.limits.global_rate_limit or
         length(origin_events) >= state.limits.origin_rate_limit do
      {{:error, :fetch_rate_limited}, state}
    else
      state = %{
        state
        | global_events: [now | global_events],
          origin_events: Map.put(state.origin_events, origin, [now | origin_events])
      }

      {:ok, state}
    end
  end

  defp slot_available?(state, origin) do
    map_size(state.active) < state.limits.max_global and
      Map.get(state.active_by_origin, origin, 0) < state.limits.max_per_origin
  end

  defp activate(state, origin, {owner, _tag}) do
    token = make_ref()
    monitor_ref = Process.monitor(owner)
    active = Map.put(state.active, token, %{origin: origin, monitor_ref: monitor_ref})

    active_by_origin =
      Map.update(state.active_by_origin, origin, 1, &(&1 + 1))

    {token, %{state | active: active, active_by_origin: active_by_origin}}
  end

  defp enqueue(state, origin, {owner, _tag} = from) do
    monitor_ref = Process.monitor(owner)

    timer_ref =
      Process.send_after(self(), {:queue_timeout, monitor_ref}, state.limits.queue_timeout_ms)

    entry = %{
      from: from,
      origin: origin,
      monitor_ref: monitor_ref,
      timer_ref: timer_ref
    }

    %{state | queue: :queue.in(entry, state.queue), queued_count: state.queued_count + 1}
  end

  defp release(state, token, opts \\ []) do
    case Map.pop(state.active, token) do
      {nil, _active} ->
        state

      {%{origin: origin, monitor_ref: monitor_ref}, active} ->
        if Keyword.get(opts, :demonitor, true), do: Process.demonitor(monitor_ref, [:flush])

        active_by_origin = decrement_origin(state.active_by_origin, origin)
        %{state | active: active, active_by_origin: active_by_origin}
    end
  end

  defp decrement_origin(counts, origin) do
    case Map.get(counts, origin, 0) do
      count when count <= 1 -> Map.delete(counts, origin)
      count -> Map.put(counts, origin, count - 1)
    end
  end

  defp dispatch_queue(%{queued_count: 0} = state), do: state

  defp dispatch_queue(state) do
    {kept, state} =
      state.queue
      |> :queue.to_list()
      |> Enum.reduce({[], %{state | queue: :queue.new(), queued_count: 0}}, fn entry,
                                                                               {kept, state} ->
        if slot_available?(state, entry.origin) do
          _ = Process.cancel_timer(entry.timer_ref)
          Process.demonitor(entry.monitor_ref, [:flush])
          {token, state} = activate(state, entry.origin, entry.from)
          GenServer.reply(entry.from, {:ok, token})
          {kept, state}
        else
          {[entry | kept], state}
        end
      end)

    kept = Enum.reverse(kept)
    %{state | queue: :queue.from_list(kept), queued_count: length(kept)}
  end

  defp remove_queued(state, monitor_ref) do
    {removed, kept} =
      state.queue
      |> :queue.to_list()
      |> Enum.reduce({nil, []}, fn entry, {removed, kept} ->
        if is_nil(removed) and entry.monitor_ref == monitor_ref do
          _ = Process.cancel_timer(entry.timer_ref)
          {entry, kept}
        else
          {removed, [entry | kept]}
        end
      end)

    kept = Enum.reverse(kept)

    {removed, %{state | queue: :queue.from_list(kept), queued_count: length(kept)}}
  end

  defp find_active_token(state, monitor_ref) do
    Enum.find_value(state.active, fn
      {token, %{monitor_ref: ^monitor_ref}} -> token
      _entry -> nil
    end)
  end
end
