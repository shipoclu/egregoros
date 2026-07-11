defmodule Egregoros.MiniApps.Fetcher.BoundedHTTP do
  @moduledoc """
  A single-use Req adapter with a bounded HTTP/1 response parser.

  Mint's TLS transport is retained for peer verification and SNI, but response
  status lines, fields, and trailers are read directly from a passive socket.
  The socket's line packet parser has its own per-line cap, so an attacker can
  never make Mint or Req buffer an unbounded field before application limits
  are enforced. Each connection is closed after one response.
  """

  alias Egregoros.MiniApps.Fetcher.BoundedHTTPError

  @max_field_line_bytes 8_192
  @max_chunk_line_bytes 1_024
  @max_body_chunks 4_096
  @body_read_bytes 8_192
  @forbidden_transport_options [
    :alpn_advertised_protocols,
    :cert,
    :certfile,
    :customize_hostname_check,
    :key,
    :keyfile,
    :partial_chain,
    :password,
    :server_name_indication,
    :verify,
    :verify_fun
  ]
  @forbidden_trailer_fields ~w(
    authorization
    connection
    content-encoding
    content-length
    content-range
    content-type
    host
    proxy-authenticate
    proxy-authorization
    set-cookie
    te
    trailer
    transfer-encoding
  )

  def run(%Req.Request{} = request, opts) when is_list(opts) do
    result = fetch(request, opts)

    case result do
      {:ok, response} -> {request, response}
      {:error, reason} -> {request, BoundedHTTPError.exception(reason: reason)}
    end
  rescue
    _error -> {request, BoundedHTTPError.exception(reason: :fetch_failed)}
  catch
    :exit, _reason -> {request, BoundedHTTPError.exception(reason: :fetch_failed)}
  end

  defp fetch(request, opts) do
    with {:ok, limits} <- limits(opts),
         {:ok, transport, address, port} <- destination(request.url),
         {:ok, request_data} <- encode_request(request),
         {:ok, socket} <- connect(transport, address, port, limits) do
      try do
        with :ok <- send_data(transport, socket, request_data),
             {:ok, status, headers, budget} <- read_head(transport, socket, limits),
             {:ok, body, trailers} <-
               read_body(transport, socket, status, headers, budget, limits) do
          {:ok,
           Req.Response.new(
             status: status,
             headers: headers,
             trailers: trailers,
             body: body
           )}
        end
      after
        _ = transport.close(socket)
      end
    end
  end

  defp limits(opts) do
    limits = %{
      hostname: Keyword.get(opts, :hostname),
      connect_timeout: Keyword.get(opts, :connect_timeout),
      receive_timeout: Keyword.get(opts, :receive_timeout),
      max_header_bytes: Keyword.get(opts, :max_header_bytes),
      max_header_count: Keyword.get(opts, :max_header_count),
      max_body_bytes: Keyword.get(opts, :max_body_bytes),
      max_redirect_body_bytes: Keyword.get(opts, :max_redirect_body_bytes),
      transport_opts: secure_transport_opts(Keyword.get(opts, :transport_opts, []))
    }

    if valid_limits?(limits), do: {:ok, limits}, else: {:error, :invalid_fetch_options}
  end

  defp valid_limits?(limits) do
    is_binary(limits.hostname) and limits.hostname != "" and
      Enum.all?(
        [
          limits.connect_timeout,
          limits.receive_timeout,
          limits.max_header_bytes,
          limits.max_header_count,
          limits.max_body_bytes,
          limits.max_redirect_body_bytes
        ],
        &(is_integer(&1) and &1 > 0)
      )
  end

  defp secure_transport_opts(opts) do
    opts
    |> List.wrap()
    |> Keyword.drop(@forbidden_transport_options)
  end

  defp destination(%URI{scheme: scheme, host: host, port: port})
       when scheme in ["http", "https"] and is_binary(host) do
    with {:ok, address} <- :inet.parse_address(String.to_charlist(host)) do
      transport = if scheme == "https", do: Mint.Core.Transport.SSL, else: Mint.Core.Transport.TCP
      {:ok, transport, address, port || if(scheme == "https", do: 443, else: 80)}
    else
      _ -> {:error, :unpinned_fetch_address}
    end
  end

  defp destination(_url), do: {:error, :unpinned_fetch_address}

  defp connect(transport, address, port, limits) do
    family_options =
      case tuple_size(address) do
        4 -> [inet4: true, inet6: false]
        8 -> [inet4: false, inet6: true]
      end

    options =
      limits.transport_opts
      |> Keyword.merge(family_options)
      |> Keyword.put(:hostname, limits.hostname)
      |> Keyword.put(:timeout, limits.connect_timeout)
      |> Keyword.put(:recbuf, @body_read_bytes)
      |> Keyword.put(:buffer, @body_read_bytes)

    case transport.connect(address, port, options) do
      {:ok, socket} -> {:ok, socket}
      {:error, %{reason: reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_request(%Req.Request{method: :get, url: url} = request) do
    with {:ok, target} <- request_target(url),
         headers <- Req.Fields.get_list(request.headers),
         {:ok, headers} <- encode_headers(headers) do
      {:ok, ["GET ", target, " HTTP/1.1\r\n", headers, "connection: close\r\n\r\n"]}
    end
  end

  defp encode_request(_request), do: {:error, :invalid_fetch_request}

  defp request_target(%URI{path: path, query: query, fragment: fragment})
       when fragment in [nil, ""] do
    path = if path in [nil, ""], do: "/", else: path
    target = if query in [nil, ""], do: path, else: path <> "?" <> query

    if String.starts_with?(target, "/") and safe_request_value?(target),
      do: {:ok, target},
      else: {:error, :invalid_fetch_request}
  end

  defp request_target(_url), do: {:error, :invalid_fetch_request}

  defp encode_headers(headers) when is_list(headers) do
    headers
    |> Enum.reject(fn {name, _value} -> name == "connection" end)
    |> Enum.reduce_while({:ok, []}, fn
      {name, value}, {:ok, acc} when is_binary(name) and is_binary(value) ->
        if field_name?(name) and safe_request_value?(value) do
          {:cont, {:ok, [[name, ": ", value, "\r\n"] | acc]}}
        else
          {:halt, {:error, :invalid_fetch_request}}
        end

      _header, _acc ->
        {:halt, {:error, :invalid_fetch_request}}
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      error -> error
    end
  end

  defp encode_headers(_headers), do: {:error, :invalid_fetch_request}

  defp safe_request_value?(value) do
    String.valid?(value) and
      value
      |> :binary.bin_to_list()
      |> Enum.all?(&(&1 >= 0x20 and &1 != 0x7F))
  end

  defp send_data(transport, socket, data) do
    case transport.send(socket, data) do
      :ok -> :ok
      {:error, %{reason: reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_head(transport, socket, limits) do
    max_line_bytes = min(@max_field_line_bytes, limits.max_header_bytes)

    with :ok <- set_line_mode(transport, socket, max_line_bytes),
         {:ok, status_line} <- recv_header_line(transport, socket, limits.receive_timeout),
         {:ok, budget} <- add_budget(%{bytes: 0, count: 0}, status_line, false, limits),
         {:ok, status} <- parse_status(status_line) do
      read_fields(transport, socket, budget, limits, [], :headers, status)
    end
  end

  defp read_fields(transport, socket, budget, limits, fields, type, status \\ nil) do
    with {:ok, line} <- recv_header_line(transport, socket, limits.receive_timeout),
         {:ok, budget} <- add_budget(budget, line, line != "\r\n", limits) do
      if line == "\r\n" do
        fields = Enum.reverse(fields)

        case type do
          :headers -> {:ok, status, fields, budget}
          :trailers -> {:ok, fields, budget}
        end
      else
        with {:ok, field} <- parse_field(line),
             :ok <- validate_trailer_field(type, field) do
          read_fields(transport, socket, budget, limits, [field | fields], type, status)
        end
      end
    end
  end

  defp recv_header_line(transport, socket, timeout) do
    case transport.recv(socket, 0, timeout) do
      {:ok, line} when is_binary(line) -> {:ok, line}
      {:error, %{reason: _reason}} -> {:error, :invalid_response_headers}
      {:error, _reason} -> {:error, :invalid_response_headers}
    end
  end

  defp add_budget(budget, line, field?, limits) do
    bytes = budget.bytes + byte_size(line)
    count = budget.count + if(field?, do: 1, else: 0)

    if bytes <= limits.max_header_bytes and count <= limits.max_header_count,
      do: {:ok, %{bytes: bytes, count: count}},
      else: {:error, :invalid_response_headers}
  end

  defp parse_status(<<"HTTP/1.", minor, " ", hundreds, tens, ones, rest::binary>> = line)
       when minor in [?0, ?1] and hundreds in ?0..?9 and tens in ?0..?9 and ones in ?0..?9 do
    if valid_status_suffix?(rest) and line_terminated?(line) do
      status = (hundreds - ?0) * 100 + (tens - ?0) * 10 + (ones - ?0)

      if status >= 200, do: {:ok, status}, else: {:error, :invalid_response_headers}
    else
      {:error, :invalid_response_headers}
    end
  end

  defp parse_status(_line), do: {:error, :invalid_response_headers}

  defp valid_status_suffix?("\r\n"), do: true

  defp valid_status_suffix?(<<" ", reason::binary>>) do
    reason
    |> strip_crlf()
    |> case do
      {:ok, reason} -> valid_field_value?(reason)
      :error -> false
    end
  end

  defp valid_status_suffix?(_rest), do: false

  defp parse_field(line) do
    with true <- line_terminated?(line),
         {:ok, field_line} <- strip_crlf(line),
         {colon, 1} <- :binary.match(field_line, ":"),
         name when byte_size(name) > 0 <- binary_part(field_line, 0, colon),
         true <- field_name?(name),
         value <- binary_part(field_line, colon + 1, byte_size(field_line) - colon - 1),
         value <- trim_ows(value),
         true <- valid_field_value?(value) do
      {:ok, {String.downcase(name, :ascii), value}}
    else
      _ -> {:error, :invalid_response_headers}
    end
  end

  defp line_terminated?(line), do: byte_size(line) >= 2 and String.ends_with?(line, "\r\n")

  defp strip_crlf(line) when byte_size(line) >= 2 do
    if line_terminated?(line),
      do: {:ok, binary_part(line, 0, byte_size(line) - 2)},
      else: :error
  end

  defp strip_crlf(_line), do: :error

  defp field_name?(name) when is_binary(name) and name != "" do
    name
    |> :binary.bin_to_list()
    |> Enum.all?(&token_byte?/1)
  end

  defp field_name?(_name), do: false

  defp token_byte?(byte) when byte in ?0..?9 or byte in ?A..?Z or byte in ?a..?z, do: true
  defp token_byte?(byte) when byte in ~c"!#$%&'*+-.^_`|~", do: true
  defp token_byte?(_byte), do: false

  defp trim_ows(value) do
    value
    |> trim_leading_ows()
    |> trim_trailing_ows()
  end

  defp trim_leading_ows(<<byte, rest::binary>>) when byte in [32, 9],
    do: trim_leading_ows(rest)

  defp trim_leading_ows(value), do: value

  defp trim_trailing_ows(<<>>), do: ""

  defp trim_trailing_ows(value) do
    if :binary.last(value) in [32, 9],
      do: value |> binary_part(0, byte_size(value) - 1) |> trim_trailing_ows(),
      else: value
  end

  defp valid_field_value?(value) when is_binary(value) do
    String.valid?(value) and
      value
      |> :binary.bin_to_list()
      |> Enum.all?(fn byte -> byte == ?\t or (byte >= 0x20 and byte != 0x7F) end)
  end

  defp validate_trailer_field(:headers, _field), do: :ok

  defp validate_trailer_field(:trailers, {name, _value}) do
    if name in @forbidden_trailer_fields,
      do: {:error, :invalid_response_headers},
      else: :ok
  end

  defp read_body(transport, socket, status, headers, budget, limits) do
    max_bytes =
      if status in 300..399,
        do: min(limits.max_body_bytes, limits.max_redirect_body_bytes),
        else: limits.max_body_bytes

    with {:ok, framing} <- response_framing(status, headers),
         :ok <- set_raw_mode(transport, socket) do
      case framing do
        {:length, length} -> read_length_body(transport, socket, length, max_bytes, limits)
        :chunked -> read_chunked_body(transport, socket, budget, max_bytes, limits)
        :close -> read_close_body(transport, socket, max_bytes, limits)
        :none -> {:ok, "", []}
      end
    end
  end

  defp response_framing(status, headers) do
    content_lengths = field_values(headers, "content-length")
    transfer_encodings = field_values(headers, "transfer-encoding")

    cond do
      status in [204, 304] and content_lengths == [] and transfer_encodings == [] ->
        {:ok, :none}

      transfer_encodings == ["chunked"] and content_lengths == [] ->
        {:ok, :chunked}

      transfer_encodings != [] ->
        {:error, :invalid_response_headers}

      content_lengths == [] ->
        {:ok, :close}

      length(content_lengths) == 1 ->
        parse_content_length(hd(content_lengths))

      true ->
        {:error, :invalid_response_headers}
    end
  end

  defp parse_content_length(value) do
    if byte_size(value) in 1..20 and digits?(value) do
      case Integer.parse(value) do
        {length, ""} -> {:ok, {:length, length}}
        _ -> {:error, :invalid_response_headers}
      end
    else
      {:error, :invalid_response_headers}
    end
  end

  defp digits?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 in ?0..?9))
  end

  defp field_values(headers, name) do
    for {^name, value} <- headers, do: String.downcase(String.trim(value), :ascii)
  end

  defp read_length_body(_transport, _socket, length, max_bytes, _limits)
       when length > max_bytes,
       do: {:error, :response_too_large}

  defp read_length_body(transport, socket, length, _max_bytes, limits) do
    case read_exact(transport, socket, length, limits.receive_timeout, []) do
      {:ok, chunks} -> {:ok, chunks_to_binary(chunks), []}
      {:error, :closed} -> {:error, :invalid_response_body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_close_body(transport, socket, max_bytes, limits) do
    read_until_close(transport, socket, max_bytes, limits.receive_timeout, [], 0)
  end

  defp read_until_close(transport, socket, max_bytes, timeout, chunks, size) do
    case recv_data(transport, socket, 0, timeout) do
      {:ok, data} when data != "" ->
        new_size = size + byte_size(data)

        if new_size > max_bytes do
          {:error, :response_too_large}
        else
          read_until_close(transport, socket, max_bytes, timeout, [data | chunks], new_size)
        end

      {:ok, ""} ->
        {:error, :invalid_response_body}

      {:error, :closed} ->
        {:ok, chunks_to_binary(chunks), []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_chunked_body(transport, socket, budget, max_bytes, limits) do
    read_chunks(transport, socket, budget, max_bytes, limits, [], 0, 0, 0)
  end

  defp read_chunks(
         _transport,
         _socket,
         _budget,
         _max_bytes,
         _limits,
         _chunks,
         _size,
         chunk_count,
         _metadata_bytes
       )
       when chunk_count >= @max_body_chunks,
       do: {:error, :invalid_response_body}

  defp read_chunks(
         transport,
         socket,
         budget,
         max_bytes,
         limits,
         chunks,
         size,
         chunk_count,
         metadata_bytes
       ) do
    with :ok <- set_line_mode(transport, socket, @max_chunk_line_bytes),
         {:ok, line} <- recv_chunk_line(transport, socket, limits.receive_timeout),
         metadata_bytes = metadata_bytes + byte_size(line),
         true <- metadata_bytes <= limits.max_header_bytes,
         {:ok, chunk_size} <- parse_chunk_size(line) do
      cond do
        chunk_size == 0 ->
          with :ok <-
                 set_line_mode(
                   transport,
                   socket,
                   min(@max_field_line_bytes, limits.max_header_bytes)
                 ),
               {:ok, trailers, _budget} <-
                 read_fields(transport, socket, budget, limits, [], :trailers) do
            {:ok, chunks_to_binary(chunks), trailers}
          end

        chunk_size > max_bytes - size ->
          {:error, :response_too_large}

        true ->
          with :ok <- set_raw_mode(transport, socket),
               {:ok, data_chunks} <-
                 read_exact(transport, socket, chunk_size, limits.receive_timeout, []),
               {:ok, ["\r\n"]} <-
                 read_exact(transport, socket, 2, limits.receive_timeout, []) do
            data = chunks_to_binary(data_chunks)

            read_chunks(
              transport,
              socket,
              budget,
              max_bytes,
              limits,
              [data | chunks],
              size + chunk_size,
              chunk_count + 1,
              metadata_bytes + 2
            )
          else
            _ -> {:error, :invalid_response_body}
          end
      end
    else
      false -> {:error, :invalid_response_body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_chunk_line(transport, socket, timeout) do
    case transport.recv(socket, 0, timeout) do
      {:ok, line} when is_binary(line) -> {:ok, line}
      {:error, %{reason: _reason}} -> {:error, :invalid_response_body}
      {:error, _reason} -> {:error, :invalid_response_body}
    end
  end

  defp parse_chunk_size(line) do
    with {:ok, value} <- strip_crlf(line),
         true <- byte_size(value) in 1..16,
         true <- hex_digits?(value),
         {size, ""} <- Integer.parse(value, 16) do
      {:ok, size}
    else
      _ -> {:error, :invalid_response_body}
    end
  end

  defp hex_digits?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f or &1 in ?A..?F))
  end

  defp read_exact(_transport, _socket, 0, _timeout, chunks), do: {:ok, chunks}

  defp read_exact(transport, socket, remaining, timeout, chunks) do
    requested = min(@body_read_bytes, remaining)

    case recv_data(transport, socket, requested, timeout) do
      {:ok, data} when byte_size(data) <= remaining ->
        read_exact(transport, socket, remaining - byte_size(data), timeout, [data | chunks])

      {:ok, _data} ->
        {:error, :invalid_response_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_data(transport, socket, bytes, timeout) do
    case transport.recv(socket, bytes, timeout) do
      {:ok, data} -> {:ok, data}
      {:error, %{reason: reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp set_line_mode(transport, socket, packet_size) do
    setopts(transport, socket, packet: :line, packet_size: packet_size)
  end

  defp set_raw_mode(transport, socket) do
    setopts(transport, socket, packet: :raw)
  end

  defp setopts(transport, socket, options) do
    case transport.setopts(socket, options) do
      :ok -> :ok
      {:error, %{reason: reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp chunks_to_binary(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()
end
