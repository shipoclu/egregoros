defmodule Egregoros.MiniApps.FetchLifecycleTest do
  use ExUnit.Case, async: true

  alias Egregoros.MiniApps.FetchGate
  alias Egregoros.MiniApps.FetchLifecycle
  alias Egregoros.MiniApps.Fetcher.BoundedHTTP

  @limits [
    hostname: "app.example",
    connect_timeout: 500,
    receive_timeout: 5_000,
    max_header_bytes: 32_768,
    max_header_count: 64,
    max_body_bytes: 65_536,
    max_redirect_body_bytes: 8_192
  ]

  setup do
    lifecycle_supervisor = start_task_supervisor()
    worker_supervisor = start_task_supervisor()
    test_supervisor = start_task_supervisor()
    gate_name = {:global, {__MODULE__, make_ref()}}

    gate =
      start_supervised!(
        {FetchGate,
         name: gate_name,
         max_global: 1,
         max_per_origin: 1,
         max_queue: 2,
         queue_timeout_ms: 5_000,
         global_rate_limit: 100,
         origin_rate_limit: 100,
         rate_interval_ms: 60_000}
      )

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        reuseaddr: true
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    %{
      gate: gate,
      lifecycle_supervisor: lifecycle_supervisor,
      listener: listener,
      port: port,
      test_supervisor: test_supervisor,
      worker_supervisor: worker_supervisor
    }
  end

  test "the network worker owns its gate permit and caller death reaps a slow socket", context do
    parent = self()

    server =
      Task.Supervisor.async_nolink(context.test_supervisor, fn ->
        {:ok, socket} = :gen_tcp.accept(context.listener, 1_000)
        {:ok, _request} = recv_request(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"
          )

        send(parent, {:slow_socket_open, socket})
        result = :gen_tcp.recv(socket, 0, 2_000)
        send(parent, {:slow_socket_result, result})
        :gen_tcp.close(socket)
      end)

    caller =
      Task.Supervisor.async_nolink(context.test_supervisor, fn ->
        run_fetch(context, 5_000)
      end)

    assert_receive {:slow_socket_open, _socket}

    assert [{:process, permit_owner}] = Process.info(context.gate, :monitors) |> elem(1)
    assert permit_owner != caller.pid
    assert Process.alive?(permit_owner)

    second_server =
      Task.Supervisor.async_nolink(context.test_supervisor, fn ->
        {:ok, socket} = :gen_tcp.accept(context.listener, 1_000)
        send(parent, :second_socket_open)
        {:ok, _request} = recv_request(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{}"
          )

        :gen_tcp.close(socket)
      end)

    second_caller =
      Task.Supervisor.async_nolink(context.test_supervisor, fn ->
        run_fetch(context, 5_000)
      end)

    assert_gate_queue_size(context.gate, 1)
    refute_receive :second_socket_open, 25

    caller_ref = caller.ref
    Process.exit(caller.pid, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, _pid, :killed}
    assert_receive {:slow_socket_result, {:error, :closed}}, 1_000
    assert_receive :second_socket_open, 1_000
    assert :ok = Task.await(server, 1_000)
    assert :ok = Task.await(second_server, 1_000)
    assert {:ok, %Req.Response{body: "{}"}} = Task.await(second_caller, 1_000)

    assert_gate_idle(context.gate)

    assert :replacement =
             FetchLifecycle.run("https://app.example", fn -> :replacement end,
               timeout_ms: 250,
               gate: context.gate,
               lifecycle_supervisor: context.lifecycle_supervisor,
               worker_supervisor: context.worker_supervisor
             )
  end

  test "an absolute lifecycle deadline reaps a slow close-delimited response", context do
    parent = self()

    server =
      Task.Supervisor.async_nolink(context.test_supervisor, fn ->
        {:ok, socket} = :gen_tcp.accept(context.listener, 1_000)
        {:ok, _request} = recv_request(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"
          )

        send(parent, :deadline_socket_open)
        result = :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.close(socket)
        result
      end)

    caller =
      Task.Supervisor.async_nolink(context.test_supervisor, fn ->
        run_fetch(context, 500)
      end)

    assert_receive :deadline_socket_open
    assert {:error, :total_timeout} = Task.await(caller, 1_000)
    assert {:error, :closed} = Task.await(server, 1_000)

    assert_gate_idle(context.gate)

    assert :capacity_recovered =
             FetchLifecycle.run("https://app.example", fn -> :capacity_recovered end,
               timeout_ms: 250,
               gate: context.gate,
               lifecycle_supervisor: context.lifecycle_supervisor,
               worker_supervisor: context.worker_supervisor
             )
  end

  defp run_fetch(context, timeout_ms) do
    FetchLifecycle.run(
      "https://app.example",
      fn -> raw_fetch(context.port) end,
      timeout_ms: timeout_ms,
      gate: context.gate,
      lifecycle_supervisor: context.lifecycle_supervisor,
      worker_supervisor: context.worker_supervisor
    )
  end

  defp raw_fetch(port) do
    Req.get("http://127.0.0.1:#{port}/resource",
      adapter: &BoundedHTTP.run(&1, @limits),
      headers: [{"host", "app.example"}],
      compressed: false,
      decode_body: false,
      raw: true,
      redirect: false,
      retry: false
    )
  end

  defp recv_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, data} -> recv_request(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp assert_gate_idle(gate) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    await_gate_idle(gate, deadline)
  end

  defp await_gate_idle(gate, deadline) do
    state = :sys.get_state(gate)

    cond do
      state.active == %{} and state.active_by_origin == %{} and state.queued_count == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("fetch gate did not return to an idle state")

      true ->
        receive do
        after
          1 -> await_gate_idle(gate, deadline)
        end
    end
  end

  defp assert_gate_queue_size(gate, expected) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    await_gate_queue_size(gate, expected, deadline)
  end

  defp await_gate_queue_size(gate, expected, deadline) do
    state = :sys.get_state(gate)

    cond do
      state.queued_count == expected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected fetch-gate queue size #{expected}, got #{state.queued_count}")

      true ->
        receive do
        after
          1 -> await_gate_queue_size(gate, expected, deadline)
        end
    end
  end

  defp start_task_supervisor do
    start_supervised!(Supervisor.child_spec(Task.Supervisor, id: {Task.Supervisor, make_ref()}))
  end
end
