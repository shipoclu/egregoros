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

  test "rejects invalid lifecycle inputs and deadline options", context do
    valid_fun = fn -> :ok end

    for {origin, fun, opts} <- [
          {nil, valid_fun, []},
          {"https://app.example", :not_a_function, []},
          {"https://app.example", fn _argument -> :ok end, []},
          {"https://app.example", valid_fun, %{}},
          {"https://app.example", valid_fun, timeout_ms: nil},
          {"https://app.example", valid_fun, timeout_ms: 0},
          {"https://app.example", valid_fun, timeout_ms: -1},
          {"https://app.example", valid_fun, timeout_ms: 10_001},
          {"https://app.example", valid_fun, timeout_ms: 1.5}
        ] do
      assert {:error, :invalid_fetch_lifecycle} = FetchLifecycle.run(origin, fun, opts)
    end

    assert :ok =
             FetchLifecycle.run("https://app.example", valid_fun,
               timeout_ms: 10_000,
               gate: context.gate,
               lifecycle_supervisor: context.lifecycle_supervisor,
               worker_supervisor: context.worker_supervisor
             )
  end

  test "contains raised, thrown, and exited worker failures and recovers capacity", context do
    options = lifecycle_options(context)

    assert {:error, :fetch_failed} =
             FetchLifecycle.run(
               "https://app.example",
               fn -> raise "untrusted fetch failure" end,
               options
             )

    assert {:error, :fetch_failed} =
             FetchLifecycle.run(
               "https://app.example",
               fn -> throw(:untrusted_fetch_failure) end,
               options
             )

    assert {:error, :fetch_unavailable} =
             FetchLifecycle.run(
               "https://app.example",
               fn -> exit(:untrusted_fetch_failure) end,
               options
             )

    assert_gate_idle(context.gate)

    assert :capacity_recovered =
             FetchLifecycle.run("https://app.example", fn -> :capacity_recovered end, options)
  end

  test "fails closed when either task supervisor is unavailable", context do
    unavailable = {:global, {__MODULE__, make_ref()}}

    assert {:error, :fetch_unavailable} =
             FetchLifecycle.run("https://app.example", fn -> :not_run end,
               timeout_ms: 250,
               gate: context.gate,
               lifecycle_supervisor: unavailable,
               worker_supervisor: context.worker_supervisor
             )

    assert {:error, :fetch_unavailable} =
             FetchLifecycle.run("https://app.example", fn -> :not_run end,
               timeout_ms: 250,
               gate: context.gate,
               lifecycle_supervisor: context.lifecycle_supervisor,
               worker_supervisor: unavailable
             )

    assert_gate_idle(context.gate)
  end

  test "preserves bounded gate errors without running the fetch", context do
    parent = self()
    unavailable = {:global, {__MODULE__, make_ref()}}

    assert {:error, :fetch_gate_unavailable} =
             FetchLifecycle.run("https://app.example", fn -> send(parent, :fetch_ran) end,
               timeout_ms: 250,
               gate: unavailable,
               lifecycle_supervisor: context.lifecycle_supervisor,
               worker_supervisor: context.worker_supervisor
             )

    assert {:error, :invalid_fetch_origin} =
             FetchLifecycle.run(String.duplicate("x", 257), fn -> send(parent, :fetch_ran) end,
               timeout_ms: 250,
               gate: context.gate,
               lifecycle_supervisor: context.lifecycle_supervisor,
               worker_supervisor: context.worker_supervisor
             )

    refute_receive :fetch_ran
    assert_gate_idle(context.gate)
  end

  test "uses the supervised production boundary when no options are supplied" do
    origin = "https://default-#{Ecto.UUID.generate()}.example"

    assert :defaults_work = FetchLifecycle.run(origin, fn -> :defaults_work end)
  end

  test "reports exhausted coordinator and worker supervisors without leaking permits", context do
    exhausted_lifecycle = start_task_supervisor(max_children: 0)
    exhausted_worker = start_task_supervisor(max_children: 0)

    assert {:error, :fetch_capacity_exhausted} =
             FetchLifecycle.run("https://app.example", fn -> :not_run end,
               timeout_ms: 250,
               gate: context.gate,
               lifecycle_supervisor: exhausted_lifecycle,
               worker_supervisor: context.worker_supervisor
             )

    assert {:error, :fetch_capacity_exhausted} =
             FetchLifecycle.run("https://app.example", fn -> :not_run end,
               timeout_ms: 250,
               gate: context.gate,
               lifecycle_supervisor: context.lifecycle_supervisor,
               worker_supervisor: exhausted_worker
             )

    assert_gate_idle(context.gate)
  end

  test "contains a worker that terminates without returning and releases its gate permit",
       context do
    assert {:error, :fetch_failed} =
             FetchLifecycle.run(
               "https://app.example",
               fn -> Process.exit(self(), :normal) end,
               lifecycle_options(context)
             )

    assert_gate_idle(context.gate)
  end

  test "fails closed when an untrappable worker death takes down its coordinator", context do
    assert {:error, :fetch_unavailable} =
             FetchLifecycle.run(
               "https://app.example",
               fn -> Process.exit(self(), :kill) end,
               lifecycle_options(context)
             )

    assert_gate_idle(context.gate)

    assert :capacity_recovered =
             FetchLifecycle.run(
               "https://app.example",
               fn -> :capacity_recovered end,
               lifecycle_options(context)
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

  defp lifecycle_options(context) do
    [
      timeout_ms: 250,
      gate: context.gate,
      lifecycle_supervisor: context.lifecycle_supervisor,
      worker_supervisor: context.worker_supervisor
    ]
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

  defp start_task_supervisor(opts \\ []) do
    child_spec = {Task.Supervisor, opts}
    start_supervised!(Supervisor.child_spec(child_spec, id: {Task.Supervisor, make_ref()}))
  end
end
