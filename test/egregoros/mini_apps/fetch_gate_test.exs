defmodule Egregoros.MiniApps.FetchGateTest do
  use ExUnit.Case, async: true

  alias Egregoros.MiniApps.FetchGate

  test "bounds active fetches and rejects work beyond the bounded queue" do
    gate = unique_name()

    start_supervised!(
      {FetchGate,
       name: gate,
       max_global: 1,
       max_per_origin: 1,
       max_queue: 1,
       queue_timeout_ms: 5_000,
       global_rate_limit: 100,
       origin_rate_limit: 100,
       rate_interval_ms: 60_000}
    )

    parent = self()

    first =
      start_fetch_task(fn ->
        FetchGate.run(
          "https://one.example",
          fn ->
            send(parent, :first_acquired)

            receive do
              :release -> :first_done
            end
          end,
          server: gate
        )
      end)

    assert_receive :first_acquired

    second =
      start_fetch_task(fn ->
        send(parent, :second_calling)

        FetchGate.run(
          "https://two.example",
          fn ->
            send(parent, :second_acquired)
            :second_done
          end,
          server: gate
        )
      end)

    assert_receive :second_calling
    _ = :sys.get_state(gate)
    refute_receive :second_acquired

    assert {:error, :fetch_queue_full} =
             FetchGate.run("https://three.example", fn -> :never end, server: gate)

    send(task_pid(first), :release)
    assert_receive :second_acquired

    assert_task_result(first, {:ok, :first_done})
    assert_task_result(second, {:ok, :second_done})
  end

  test "limits concurrent fetches independently for each exact origin" do
    gate = unique_name()

    start_supervised!(
      {FetchGate,
       name: gate,
       max_global: 3,
       max_per_origin: 1,
       max_queue: 2,
       queue_timeout_ms: 5_000,
       global_rate_limit: 100,
       origin_rate_limit: 100,
       rate_interval_ms: 60_000}
    )

    parent = self()

    first =
      start_fetch_task(fn ->
        FetchGate.run(
          "https://same.example",
          fn ->
            send(parent, {:acquired, :first})

            receive do
              :release -> :first_done
            end
          end,
          server: gate
        )
      end)

    assert_receive {:acquired, :first}

    same_origin =
      start_fetch_task(fn ->
        send(parent, :same_calling)

        FetchGate.run(
          "https://same.example",
          fn ->
            send(parent, {:acquired, :same})
            :same_done
          end,
          server: gate
        )
      end)

    assert_receive :same_calling
    _ = :sys.get_state(gate)
    refute_receive {:acquired, :same}

    other_origin =
      start_fetch_task(fn ->
        FetchGate.run(
          "https://other.example",
          fn ->
            send(parent, {:acquired, :other})
            :other_done
          end,
          server: gate
        )
      end)

    assert_receive {:acquired, :other}
    send(task_pid(first), :release)
    assert_receive {:acquired, :same}

    assert_task_result(first, {:ok, :first_done})
    assert_task_result(same_origin, {:ok, :same_done})
    assert_task_result(other_origin, {:ok, :other_done})
  end

  test "rate limits both one origin and the instance-wide fetch stream" do
    per_origin_gate = unique_name()

    start_supervised!(
      {FetchGate,
       name: per_origin_gate,
       max_global: 2,
       max_per_origin: 2,
       max_queue: 0,
       global_rate_limit: 100,
       origin_rate_limit: 2,
       rate_interval_ms: 60_000}
    )

    assert {:ok, :one} =
             FetchGate.run("https://one.example", fn -> :one end, server: per_origin_gate)

    assert {:ok, :two} =
             FetchGate.run("https://one.example", fn -> :two end, server: per_origin_gate)

    assert {:error, :fetch_rate_limited} =
             FetchGate.run("https://one.example", fn -> :never end, server: per_origin_gate)

    global_gate = unique_name()

    start_supervised!(
      Supervisor.child_spec(
        {FetchGate,
         name: global_gate,
         max_global: 2,
         max_per_origin: 2,
         max_queue: 0,
         global_rate_limit: 2,
         origin_rate_limit: 100,
         rate_interval_ms: 60_000},
        id: {FetchGate, make_ref()}
      )
    )

    assert {:ok, :one} =
             FetchGate.run("https://one.example", fn -> :one end, server: global_gate)

    assert {:ok, :two} =
             FetchGate.run("https://two.example", fn -> :two end, server: global_gate)

    assert {:error, :fetch_rate_limited} =
             FetchGate.run("https://three.example", fn -> :never end, server: global_gate)
  end

  test "times queued work out and releases permits when their owner exits" do
    gate = unique_name()

    start_supervised!(
      {FetchGate,
       name: gate,
       max_global: 1,
       max_per_origin: 1,
       max_queue: 1,
       queue_timeout_ms: 10,
       global_rate_limit: 100,
       origin_rate_limit: 100,
       rate_interval_ms: 60_000}
    )

    parent = self()

    owner =
      start_fetch_task(fn ->
        FetchGate.run(
          "https://one.example",
          fn ->
            send(parent, :owner_acquired)

            receive do
              :release -> :done
            end
          end,
          server: gate
        )
      end)

    assert_receive :owner_acquired

    timed_out =
      start_fetch_task(fn ->
        FetchGate.run("https://two.example", fn -> :never end, server: gate)
      end)

    assert_task_result(timed_out, {:error, :fetch_queue_timeout}, 1_000)

    replacement =
      start_fetch_task(fn ->
        FetchGate.run(
          "https://three.example",
          fn ->
            send(parent, :replacement_acquired)
            :replacement_done
          end,
          server: gate
        )
      end)

    Process.exit(task_pid(owner), :kill)
    assert_task_exit(owner, :killed)
    assert_receive :replacement_acquired
    assert_task_result(replacement, {:ok, :replacement_done})
  end

  test "the gate owns wait timeouts so a delayed call cannot create an orphan permit" do
    gate = unique_name()

    start_supervised!(
      {FetchGate,
       name: gate,
       max_global: 1,
       max_per_origin: 1,
       max_queue: 1,
       queue_timeout_ms: 10,
       global_rate_limit: 100,
       origin_rate_limit: 100,
       rate_interval_ms: 60_000}
    )

    :ok = :sys.suspend(gate)
    parent = self()

    delayed =
      start_fetch_task(fn ->
        send(parent, :delayed_calling)

        FetchGate.run(
          "https://one.example",
          fn ->
            send(parent, :delayed_acquired)
            :delayed_done
          end,
          server: gate
        )
      end)

    assert_receive :delayed_calling
    {_pid, result_ref, _monitor_ref} = delayed

    # This exceeds the old client-side GenServer.call timeout. The caller must
    # remain blocked until the gate can either grant it or apply its own queue
    # timeout; otherwise a late grant can strand an active permit.
    refute_receive {:fetch_result, ^result_ref, _result}, 6_100

    :ok = :sys.resume(gate)
    assert_receive :delayed_acquired
    assert_task_result(delayed, {:ok, :delayed_done})

    assert {:ok, :replacement} =
             FetchGate.run("https://two.example", fn -> :replacement end, server: gate)
  end

  defp start_fetch_task(fun) do
    parent = self()
    result_ref = make_ref()
    id = {:fetch_task, make_ref()}

    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result = fun.()
             send(parent, {:fetch_result, result_ref, result})
           end},
          id: id,
          restart: :temporary
        )
      )

    {pid, result_ref, Process.monitor(pid)}
  end

  defp assert_task_result(task, expected, timeout \\ 100)

  defp assert_task_result({pid, result_ref, monitor_ref}, expected, timeout) do
    assert_receive {:fetch_result, ^result_ref, ^expected}, timeout
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, timeout
  end

  defp assert_task_exit({pid, _result_ref, monitor_ref}, reason) do
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, ^reason}
  end

  defp task_pid({pid, _result_ref, _monitor_ref}), do: pid

  defp unique_name, do: {:global, {__MODULE__, make_ref()}}
end
