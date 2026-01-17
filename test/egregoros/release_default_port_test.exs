defmodule Egregoros.ReleaseDefaultPortTest do
  use ExUnit.Case, async: false

  alias Egregoros.Release

  defp with_tcp_server(response, fun) when is_binary(response) and is_function(fun, 1) do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_addr, port}} = :inet.sockname(listen_socket)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        _ = :gen_tcp.recv(socket, 0, 1_000)
        :ok = :gen_tcp.send(socket, response)
        :ok = :gen_tcp.close(socket)
        :ok = :gen_tcp.close(listen_socket)
      end)

    try do
      fun.(port)
    after
      _ = Task.shutdown(server, :brutal_kill)
      _ = :gen_tcp.close(listen_socket)
    end
  end

  test "healthcheck/1 uses PORT when port is not provided" do
    with_tcp_server("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", fn port ->
      previous = System.get_env("PORT")
      System.put_env("PORT", Integer.to_string(port))

      try do
        assert :ok = Release.healthcheck()
      after
        if is_binary(previous),
          do: System.put_env("PORT", previous),
          else: System.delete_env("PORT")
      end
    end)
  end
end
