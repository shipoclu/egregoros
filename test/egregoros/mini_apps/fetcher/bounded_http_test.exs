defmodule Egregoros.MiniApps.Fetcher.BoundedHTTPTest do
  use ExUnit.Case, async: true

  alias Egregoros.MiniApps.Fetcher.BoundedHTTP
  alias Egregoros.MiniApps.Fetcher.BoundedHTTPError

  @default_limits [
    hostname: "app.example",
    connect_timeout: 500,
    receive_timeout: 500,
    max_header_bytes: 32_768,
    max_header_count: 64,
    max_body_bytes: 65_536,
    max_redirect_body_bytes: 8_192
  ]

  setup do
    supervisor = start_supervised!(Task.Supervisor)
    %{task_supervisor: supervisor}
  end

  test "preserves repeated response fields instead of collapsing them", context do
    response =
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: application/json\r\n" <>
        "X-Result: first\r\n" <>
        "X-Result: second\r\n" <>
        "Content-Length: 2\r\n\r\n{}"

    assert {:ok, response} = request_raw(context, response)
    assert Req.Response.get_header(response, "x-result") == ["first", "second"]
    assert response.body == "{}"
  end

  test "reads a bounded close-delimited response without waiting for a full receive chunk",
       context do
    response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{}"

    assert {:ok, %{body: "{}"}} = request_raw(context, response)
  end

  test "rejects a repeated framing field before reading a body", context do
    response =
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: 2\r\n" <>
        "Content-Length: 2\r\n\r\n{}"

    assert {:error, %BoundedHTTPError{reason: :invalid_response_headers}} =
             request_raw(context, response)
  end

  test "counts every repeated field against the header-count limit", context do
    response =
      "HTTP/1.1 200 OK\r\n" <>
        Enum.map_join(1..5, "", &"X-Pad: #{&1}\r\n") <>
        "\r\n"

    assert {:error, %BoundedHTTPError{reason: :invalid_response_headers}} =
             request_raw(context, response, max_header_count: 4)
  end

  test "rejects an oversized field in the socket packet parser", context do
    response =
      "HTTP/1.1 200 OK\r\nX-Pad: " <>
        String.duplicate("a", 128_000) <>
        "\r\nContent-Length: 0\r\n\r\n"

    before = :erlang.process_info(self(), :memory)

    assert {:error, %BoundedHTTPError{reason: :invalid_response_headers}} =
             request_raw(context, response, max_header_bytes: 1_024)

    assert {:memory, after_bytes} = :erlang.process_info(self(), :memory)
    assert {:memory, before_bytes} = before
    assert after_bytes - before_bytes < 128_000
  end

  test "counts the raw status line against the response byte budget", context do
    response =
      "HTTP/1.1 200 " <>
        String.duplicate("a", 2_000) <>
        "\r\nContent-Length: 0\r\n\r\n"

    assert {:error, %BoundedHTTPError{reason: :invalid_response_headers}} =
             request_raw(context, response, max_header_bytes: 1_024)
  end

  test "applies the same byte and count budget to chunked trailers", context do
    response =
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Transfer-Encoding: chunked\r\n\r\n" <>
        "2\r\n{}\r\n0\r\n" <>
        "X-One: 1\r\nX-Two: 2\r\nX-Three: 3\r\n\r\n"

    assert {:error, %BoundedHTTPError{reason: :invalid_response_headers}} =
             request_raw(context, response, max_header_count: 4)
  end

  test "rejects an oversized chunked trailer in the socket packet parser", context do
    response =
      "HTTP/1.1 200 OK\r\n" <>
        "Transfer-Encoding: chunked\r\n\r\n" <>
        "0\r\nX-Pad: " <>
        String.duplicate("a", 2_000) <>
        "\r\n\r\n"

    assert {:error, %BoundedHTTPError{reason: :invalid_response_headers}} =
             request_raw(context, response, max_header_bytes: 1_024)
  end

  test "rejects a transfer coding other than one exact chunked field", context do
    for transfer_encoding <- ["gzip", "chunked, chunked", "chunked\r\nTransfer-Encoding: chunked"] do
      response =
        "HTTP/1.1 200 OK\r\n" <>
          "Transfer-Encoding: #{transfer_encoding}\r\n\r\n0\r\n\r\n"

      assert {:error, %BoundedHTTPError{reason: :invalid_response_headers}} =
               request_raw(context, response)
    end
  end

  test "bounds chunk sizes before allocating or receiving them", context do
    response =
      "HTTP/1.1 200 OK\r\n" <>
        "Transfer-Encoding: chunked\r\n\r\n10000000\r\n"

    assert {:error, %BoundedHTTPError{reason: :response_too_large}} =
             request_raw(context, response, max_body_bytes: 16)
  end

  test "connects to the pinned IP while using the original hostname for SNI and Host", context do
    test_pid = self()
    certfile = fixture_path("transport-cert.pem")
    keyfile = fixture_path("transport-key.pem")

    {:ok, listener} =
      :ssl.listen(0,
        mode: :binary,
        active: false,
        ip: {127, 0, 0, 1},
        reuseaddr: true,
        certfile: certfile,
        keyfile: keyfile,
        sni_fun: fn hostname ->
          send(test_pid, {:tls_sni, List.to_string(hostname)})
          []
        end
      )

    {:ok, {_address, port}} = :ssl.sockname(listener)

    server =
      Task.Supervisor.async_nolink(context.task_supervisor, fn ->
        {:ok, transport_socket} = :ssl.transport_accept(listener, 1_000)
        {:ok, socket} = :ssl.handshake(transport_socket, 1_000)
        {:ok, request} = recv_ssl_request(socket, "")

        :ok =
          :ssl.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
          )

        :ssl.close(socket)
        request
      end)

    limits =
      Keyword.merge(@default_limits,
        transport_opts: [cacertfile: fixture_path("transport-ca.pem")]
      )

    assert {:ok, %{body: "{}"}} =
             Req.get("https://127.0.0.1:#{port}/manifest",
               adapter: &BoundedHTTP.run(&1, limits),
               headers: [{"host", "app.example:#{port}"}],
               compressed: false,
               decode_body: false,
               raw: true,
               redirect: false,
               retry: false
             )

    assert_receive {:tls_sni, "app.example"}
    assert Task.await(server, 1_000) =~ "host: app.example:#{port}\r\n"
    :ssl.close(listener)
  end

  defp request_raw(context, response, overrides \\ []) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        reuseaddr: true
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      Task.Supervisor.async_nolink(context.task_supervisor, fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, request} = recv_request(socket, "")
        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        request
      end)

    limits = Keyword.merge(@default_limits, overrides)

    result =
      Req.get("http://127.0.0.1:#{port}/resource?mode=test",
        adapter: &BoundedHTTP.run(&1, limits),
        headers: [{"host", "app.example"}],
        compressed: false,
        decode_body: false,
        raw: true,
        redirect: false,
        retry: false
      )

    request = Task.await(server, 1_000)
    assert request =~ "GET /resource?mode=test HTTP/1.1\r\n"
    assert request =~ "host: app.example\r\n"

    :gen_tcp.close(listener)
    result
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

  defp recv_ssl_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :ssl.recv(socket, 0, 1_000) do
        {:ok, data} -> recv_ssl_request(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fixture_path(filename) do
    __DIR__
    |> Path.join("../../../fixtures/mini_apps/#{filename}")
    |> Path.expand()
    |> String.to_charlist()
  end
end
