defmodule Egregoros.MiniApps.Fetcher.Req do
  @moduledoc false

  @behaviour Egregoros.MiniApps.Fetcher

  alias Egregoros.Config
  alias Egregoros.MiniApps.FetchLifecycle
  alias Egregoros.MiniApps.Fetcher.BoundedHTTP
  alias Egregoros.MiniApps.Fetcher.BoundedHTTPError
  alias Egregoros.MiniApps.Origin
  alias Egregoros.SafeURL

  @max_redirects 2
  @max_redirect_body_bytes 8_192
  @max_header_count 64
  @max_header_bytes 32_768
  @connect_timeout_ms 2_000
  @receive_timeout_ms 3_000
  @total_timeout_ms 8_000

  @default_opts [
    redirect: false,
    retry: false,
    decode_body: false,
    compressed: false,
    raw: true,
    receive_timeout: @receive_timeout_ms
  ]

  @resource_config %{
    actor: %{
      accept: "application/activity+json,application/ld+json,application/json",
      content_types: ["application/activity+json", "application/ld+json", "application/json"],
      max_bytes: 65_536
    },
    manifest: %{
      accept: "application/json",
      content_types: ["application/json"],
      max_bytes: 65_536
    },
    page: %{accept: "text/html", content_types: ["text/html"], max_bytes: 1_000_000},
    asset: %{
      accept: "image/avif,image/webp,image/png,image/jpeg",
      content_types: ~w(image/avif image/webp image/png image/jpeg),
      max_bytes: 5_000_000
    }
  }

  @impl true
  def get(url, kind) when is_binary(url) and is_map_key(@resource_config, kind) do
    config = Map.fetch!(@resource_config, kind)

    with {:ok, canonical_url, origin} <- Origin.normalize_url(url) do
      FetchLifecycle.run(
        origin,
        fn -> request_chain(canonical_url, origin, config, @max_redirects) end,
        timeout_ms: @total_timeout_ms
      )
    else
      {:error, :invalid_url} -> {:error, :unsafe_url}
      {:error, _reason} = error -> error
    end
  end

  def get(_url, _kind), do: {:error, :unsupported_resource_kind}

  defp request_chain(url, origin, config, redirects_remaining) do
    with {:ok, connect_url, hostname, authority} <- pinned_request(url),
         {:ok, response} <- request(connect_url, hostname, authority, config),
         :ok <-
           validate_response_headers(
             response,
             response_body_limit(response.status, config.max_bytes)
           ),
         :ok <-
           validate_body_budget(
             response,
             response_body_limit(response.status, config.max_bytes)
           ),
         :ok <- validate_complete_body(response) do
      case response.status do
        200 ->
          with :ok <- validate_content_type(response, config.content_types) do
            {:ok, response_map(response)}
          end

        status when status in 300..399 and redirects_remaining > 0 ->
          with {:ok, next_url} <- redirect_url(response, url, origin) do
            request_chain(next_url, origin, config, redirects_remaining - 1)
          end

        status when status in 300..399 ->
          {:error, :too_many_redirects}

        status ->
          {:error, {:unexpected_status, status}}
      end
    end
  end

  defp request(connect_url, hostname, authority, config) do
    headers = [
      {"accept", config.accept},
      {"accept-encoding", "identity"},
      {"cache-control", "no-store"},
      {"host", authority},
      {"pragma", "no-cache"},
      {"user-agent", "Egregoros MiniApp Fetcher/1"}
    ]

    opts =
      req_options() ++
        [
          adapter: &BoundedHTTP.run(&1, bounded_http_options(hostname, config.max_bytes)),
          headers: headers
        ] ++
        @default_opts

    case Req.get(connect_url, opts) do
      {:ok, %Req.Response{body: {:error, reason}}}
      when reason in [
             :encoded_response_not_allowed,
             :invalid_response_headers,
             :invalid_response_body,
             :response_too_large
           ] ->
        {:error, reason}

      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, %BoundedHTTPError{reason: reason}} ->
        {:error, reason}

      {:error, _reason} = error ->
        error
    end
  end

  defp pinned_request(url) do
    with {:ok, %{connect_url: connect_url, hostname: hostname, authority: authority}} <-
           SafeURL.resolve_https_domain_url(url) do
      {:ok, connect_url, hostname, authority}
    end
  end

  defp req_options do
    :mini_apps_req_options
    |> Config.get([])
    |> List.wrap()
    |> Keyword.take([:plug])
  end

  defp bounded_http_options(hostname, max_body_bytes) do
    [
      hostname: hostname,
      connect_timeout: @connect_timeout_ms,
      receive_timeout: @receive_timeout_ms,
      max_header_count: @max_header_count,
      max_header_bytes: @max_header_bytes,
      max_body_bytes: max_body_bytes,
      max_redirect_body_bytes: @max_redirect_body_bytes,
      transport_opts: Config.get(:req_https_transport_opts, [])
    ]
  end

  defp response_body_limit(status, max_bytes) when status in 300..399,
    do: min(max_bytes, @max_redirect_body_bytes)

  defp response_body_limit(_status, max_bytes), do: max_bytes

  defp validate_response_headers(response, max_bytes) do
    with :ok <- validate_header_budget(response.headers),
         :ok <- validate_content_encoding(response),
         :ok <- validate_content_length(response, max_bytes),
         :ok <- reject_ambiguous_framing(response) do
      :ok
    end
  end

  defp validate_header_budget(headers) when is_list(headers) do
    bytes =
      Enum.reduce_while(headers, 0, fn
        {key, value}, acc when is_binary(key) and is_binary(value) ->
          {:cont, acc + byte_size(key) + byte_size(value)}

        _header, _acc ->
          {:halt, :invalid}
      end)

    if length(headers) <= @max_header_count and is_integer(bytes) and bytes <= @max_header_bytes,
      do: :ok,
      else: {:error, :invalid_response_headers}
  end

  defp validate_header_budget(headers) when is_map(headers) do
    headers
    |> Enum.flat_map(fn
      {key, values} when is_binary(key) ->
        values
        |> List.wrap()
        |> Enum.map(&{key, &1})

      _header ->
        [:invalid]
    end)
    |> validate_header_budget()
  end

  defp validate_header_budget(_headers), do: {:error, :invalid_response_headers}

  defp validate_content_encoding(response) do
    case Req.Response.get_header(response, "content-encoding") do
      [] ->
        :ok

      [value] when is_binary(value) ->
        if String.downcase(String.trim(value)) == "identity",
          do: :ok,
          else: {:error, :encoded_response_not_allowed}

      _ ->
        {:error, :encoded_response_not_allowed}
    end
  end

  defp validate_content_length(response, max_bytes) do
    case Req.Response.get_header(response, "content-length") do
      [] ->
        :ok

      [value] when is_binary(value) ->
        value = String.trim(value)

        if byte_size(value) <= 20 and String.match?(value, ~r/^\d+$/) do
          case Integer.parse(value) do
            {length, ""} when length <= max_bytes -> :ok
            {length, ""} when length > max_bytes -> {:error, :response_too_large}
            _ -> {:error, :invalid_response_headers}
          end
        else
          {:error, :invalid_response_headers}
        end

      _ ->
        {:error, :invalid_response_headers}
    end
  end

  defp reject_ambiguous_framing(response) do
    content_length = Req.Response.get_header(response, "content-length")
    transfer_encoding = Req.Response.get_header(response, "transfer-encoding")

    if content_length != [] and transfer_encoding != [],
      do: {:error, :invalid_response_headers},
      else: :ok
  end

  defp validate_complete_body(response) do
    case Req.Response.get_header(response, "content-length") do
      [] ->
        :ok

      [value] ->
        {declared, ""} = value |> String.trim() |> Integer.parse()
        actual = response_body_bytes(response)

        if declared == actual,
          do: :ok,
          else: {:error, :invalid_response_body}
    end
  end

  defp validate_body_budget(response, max_bytes) do
    if response_body_bytes(response) <= max_bytes,
      do: :ok,
      else: {:error, :response_too_large}
  end

  defp response_body_bytes(response) do
    case Req.Response.get_private(response, :egregoros_mini_app_body_bytes, nil) do
      size when is_integer(size) -> size
      nil when is_binary(response.body) -> byte_size(response.body)
      nil -> IO.iodata_length(response.body)
    end
  end

  defp validate_content_type(response, expected) when is_list(expected) do
    case Req.Response.get_header(response, "content-type") do
      [value] when is_binary(value) ->
        normalized =
          value
          |> String.split(";", parts: 2)
          |> List.first()
          |> String.trim()
          |> String.downcase()

        if normalized in expected and not String.contains?(normalized, ","),
          do: :ok,
          else: {:error, :invalid_content_type}

      _ ->
        {:error, :invalid_content_type}
    end
  end

  defp redirect_url(response, current_url, origin) do
    with [location] when is_binary(location) <- Req.Response.get_header(response, "location"),
         true <- byte_size(location) in 1..2_048,
         {:ok, next_url} <- merge_redirect(current_url, location),
         {:ok, ^origin} <- Origin.from_url(next_url) do
      {:ok, next_url}
    else
      {:ok, _other_origin} -> {:error, :redirect_origin_mismatch}
      _ -> {:error, :invalid_redirect}
    end
  end

  defp merge_redirect(current_url, location) do
    with {:ok, current_uri} <- URI.new(current_url),
         {:ok, location_uri} <- URI.new(location),
         merged_url = current_uri |> URI.merge(location_uri) |> URI.to_string(),
         {:ok, canonical_url, _origin} <- Origin.normalize_url(merged_url) do
      {:ok, canonical_url}
    else
      _ -> {:error, :invalid_redirect}
    end
  end

  defp response_map(response) do
    body =
      case Req.Response.get_private(response, :egregoros_mini_app_body_chunks_reversed, []) do
        [] when is_binary(response.body) -> response.body
        [] -> IO.iodata_to_binary(response.body)
        chunks -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
      end

    response
    |> Req.Response.to_map()
    |> Map.take([:status, :headers])
    |> Map.put(:body, body)
  end
end
