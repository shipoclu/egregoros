defmodule Egregoros.MiniApps.FetchLifecycle do
  @moduledoc """
  Owns one bounded mini-app fetch independently of the requesting process.

  A supervised coordinator watches both the original caller and a linked,
  supervised network worker. The worker itself acquires the fetch-gate permit,
  so that permit cannot be released while its socket is still alive. Caller
  death and the absolute lifecycle deadline both kill and reap the worker
  before the coordinator exits.
  """

  alias Egregoros.MiniApps.FetchGate

  @default_timeout_ms 8_000
  @max_timeout_ms 10_000

  @type option ::
          {:gate, GenServer.server()}
          | {:lifecycle_supervisor, GenServer.server()}
          | {:timeout_ms, pos_integer()}
          | {:worker_supervisor, GenServer.server()}

  @spec run(binary(), (-> term()), [option()]) :: term()
  def run(origin, fun, opts \\ [])

  def run(origin, fun, opts)
      when is_binary(origin) and is_function(fun, 0) and is_list(opts) do
    with {:ok, settings} <- settings(opts),
         {:ok, coordinator} <- start_coordinator(self(), origin, fun, settings) do
      await_coordinator(coordinator)
    end
  end

  def run(_origin, _fun, _opts), do: {:error, :invalid_fetch_lifecycle}

  defp settings(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    if is_integer(timeout_ms) and timeout_ms in 1..@max_timeout_ms do
      {:ok,
       %{
         deadline: System.monotonic_time(:millisecond) + timeout_ms,
         gate: Keyword.get(opts, :gate, FetchGate),
         lifecycle_supervisor:
           Keyword.get(
             opts,
             :lifecycle_supervisor,
             Egregoros.MiniAppFetchLifecycleSupervisor
           ),
         worker_supervisor:
           Keyword.get(opts, :worker_supervisor, Egregoros.MiniAppFetchTaskSupervisor)
       }}
    else
      {:error, :invalid_fetch_lifecycle}
    end
  end

  defp start_coordinator(caller, origin, fun, settings) do
    task =
      Task.Supervisor.async_nolink(settings.lifecycle_supervisor, fn ->
        coordinate(caller, origin, fun, settings)
      end)

    {:ok, task}
  rescue
    RuntimeError -> {:error, :fetch_capacity_exhausted}
  catch
    :exit, _reason -> {:error, :fetch_unavailable}
  end

  defp await_coordinator(task) do
    Task.await(task, :infinity)
  catch
    :exit, _reason -> {:error, :fetch_unavailable}
  end

  defp coordinate(caller, origin, fun, settings) do
    caller_ref = Process.monitor(caller)

    try do
      if caller_down?(caller_ref) do
        {:error, :fetch_cancelled}
      else
        case start_worker(origin, fun, settings) do
          {:ok, worker} -> await_worker(worker, caller_ref, settings.deadline)
          {:error, _reason} = error -> error
        end
      end
    after
      Process.demonitor(caller_ref, [:flush])
    end
  end

  defp caller_down?(caller_ref) do
    receive do
      {:DOWN, ^caller_ref, :process, _pid, _reason} -> true
    after
      0 -> false
    end
  end

  # The worker is linked to its independently supervised coordinator. An
  # unexpected coordinator exit therefore cannot strand the network task. For
  # expected cancellation we unlink immediately before the deliberate kill,
  # then wait for the worker monitor before returning.
  defp start_worker(origin, fun, settings) do
    task =
      Task.Supervisor.async(settings.worker_supervisor, fn ->
        invoke_worker(settings.gate, origin, fun)
      end)

    {:ok, task}
  rescue
    RuntimeError -> {:error, :fetch_capacity_exhausted}
  catch
    :exit, _reason -> {:error, :fetch_unavailable}
  end

  defp invoke_worker(gate, origin, fun) do
    FetchGate.run(origin, fun, server: gate)
  rescue
    _error -> {:error, :fetch_failed}
  catch
    :exit, _reason -> {:error, :fetch_unavailable}
    _kind, _reason -> {:error, :fetch_failed}
  end

  defp await_worker(worker, caller_ref, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {ref, result} when ref == worker.ref ->
        Process.demonitor(worker.ref, [:flush])
        unwrap_gate_result(result)

      {:DOWN, ref, :process, _pid, _reason} when ref == worker.ref ->
        {:error, :fetch_failed}

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        reap_worker(worker)
        {:error, :fetch_cancelled}
    after
      remaining ->
        reap_worker(worker)
        {:error, :total_timeout}
    end
  end

  defp unwrap_gate_result({:ok, result}), do: result
  defp unwrap_gate_result({:error, _reason} = error), do: error
  defp unwrap_gate_result(_result), do: {:error, :fetch_failed}

  defp reap_worker(worker) do
    Process.unlink(worker.pid)
    Process.exit(worker.pid, :kill)
    await_worker_down(worker.ref)
  end

  defp await_worker_down(ref) do
    receive do
      {^ref, _result} -> await_worker_down(ref)
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end
  end
end
