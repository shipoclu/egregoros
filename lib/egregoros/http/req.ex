defmodule Egregoros.HTTP.Req do
  @behaviour Egregoros.HTTP

  alias Egregoros.SafeURL

  @default_opts [redirect: false, receive_timeout: 5_000]
  @default_req_options []
  @default_max_response_bytes 1_000_000

  defp req_options do
    Egregoros.Config.get(:req_options, @default_req_options)
  end

  defp pinned_request(url) when is_binary(url) do
    with {:ok, %{connect_url: connect_url, hostname: hostname}} <-
           SafeURL.resolve_http_url_federation(url) do
      {:ok, connect_url, pinned_connect_options(url, hostname)}
    end
  end

  defp pinned_connect_options(url, hostname) when is_binary(hostname) do
    transport_opts =
      case URI.parse(url) do
        %URI{scheme: "https"} -> Egregoros.Config.get(:req_https_transport_opts, [])
        _ -> []
      end

    connect_options =
      [hostname: hostname]
      |> maybe_put_transport_opts(transport_opts)

    [connect_options: connect_options]
  end

  defp maybe_put_transport_opts(options, transport_opts)
       when is_list(transport_opts) and transport_opts != [],
       do: Keyword.put(options, :transport_opts, transport_opts)

  defp maybe_put_transport_opts(options, _transport_opts), do: options

  defp max_response_bytes do
    Egregoros.Config.get(:http_max_response_bytes, @default_max_response_bytes)
  end

  defp limited_into_fun(max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    fn {:data, chunk}, {req, resp} ->
      chunk_size = IO.iodata_length(chunk)
      current = Req.Response.get_private(resp, :egregoros_http_body_bytes, 0)
      new_size = current + chunk_size

      if new_size > max_bytes do
        resp =
          resp
          |> Req.Response.put_private(:egregoros_http_body_bytes, new_size)
          |> Map.replace!(:body, {:error, :response_too_large})

        {:halt, {req, resp}}
      else
        resp =
          resp
          |> Req.Response.put_private(:egregoros_http_body_bytes, new_size)
          |> Map.replace!(:body, resp.body <> IO.iodata_to_binary(chunk))

        {:cont, {req, resp}}
      end
    end
  end

  @impl true
  def get(url, headers) do
    with {:ok, connect_url, connect_options} <- pinned_request(url) do
      opts =
        [headers: headers, into: limited_into_fun(max_response_bytes())] ++
          req_options() ++ connect_options ++ @default_opts

      case Req.get(connect_url, opts) do
        {:ok, response} ->
          case response.body do
            {:error, :response_too_large} ->
              {:error, :response_too_large}

            body ->
              {:ok, %{status: response.status, body: body, headers: response.headers}}
          end

        {:error, _} = error ->
          error
      end
    end
  end

  @impl true
  def post(url, body, headers) do
    with {:ok, connect_url, connect_options} <- pinned_request(url) do
      opts =
        [body: body, headers: headers, into: limited_into_fun(max_response_bytes())] ++
          req_options() ++ connect_options ++ @default_opts

      case Req.post(connect_url, opts) do
        {:ok, response} ->
          case response.body do
            {:error, :response_too_large} ->
              {:error, :response_too_large}

            response_body ->
              {:ok, %{status: response.status, body: response_body, headers: response.headers}}
          end

        {:error, _} = error ->
          error
      end
    end
  end
end
