defmodule Egregoros.ReleaseHealthcheckTest do
  use ExUnit.Case, async: true

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

  test "healthcheck/1 returns :ok when the endpoint responds 200" do
    with_tcp_server("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}", fn port ->
      assert :ok = Release.healthcheck(port: port)
    end)
  end

  test "healthcheck/1 returns an error when the endpoint responds non-200" do
    with_tcp_server("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n", fn port ->
      assert {:error, :bad_status} = Release.healthcheck(port: port)
    end)
  end
end
