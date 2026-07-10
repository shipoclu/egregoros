defmodule Egregoros.MiniApps.Fetcher.Req do
  @moduledoc false

  @behaviour Egregoros.MiniApps.Fetcher

  alias Egregoros.Config
  alias Egregoros.SafeURL

  @default_opts [
    redirect: false,
    retry: false,
    decode_body: false,
    compressed: false,
    receive_timeout: 5_000
  ]

  @resource_config %{
    manifest: %{
      accept: "application/json",
      content_types: ["application/json"],
      max_bytes: 65_536
    },
    page: %{accept: "text/html", content_types: ["text/html"], max_bytes: 1_000_000},
    asset: %{
      accept: "image/avif,image/webp,image/png,image/jpeg,image/gif",
      content_types: ~w(image/avif image/webp image/png image/jpeg image/gif),
      max_bytes: 2_000_000
    }
  }

  @impl true
  def get(url, kind) when is_binary(url) and is_map_key(@resource_config, kind) do
    config = Map.fetch!(@resource_config, kind)

    with {:ok, connect_url, connect_options} <- pinned_request(url),
         {:ok, response} <- request(connect_url, connect_options, config),
         :ok <- validate_status(response.status),
         :ok <- validate_content_type(response, config.content_types) do
      {:ok, Req.Response.to_map(response) |> Map.take([:status, :body, :headers])}
    end
  end

  def get(_url, _kind), do: {:error, :unsupported_resource_kind}

  defp request(connect_url, connect_options, config) do
    opts =
      [
        headers: [
          {"accept", config.accept},
          {"user-agent", "Egregoros MiniApp Fetcher/1"}
        ],
        into: limited_into_fun(config.max_bytes)
      ] ++ req_options() ++ connect_options ++ @default_opts

    case Req.get(connect_url, opts) do
      {:ok, %Req.Response{body: {:error, :response_too_large}}} ->
        {:error, :response_too_large}

      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, _reason} = error ->
        error
    end
  end

  defp pinned_request(url) do
    with {:ok, %{connect_url: connect_url, hostname: hostname}} <-
           SafeURL.resolve_https_domain_url(url) do
      {:ok, connect_url, pinned_connect_options(hostname)}
    end
  end

  defp pinned_connect_options(hostname) do
    transport_opts = Config.get(:req_https_transport_opts, [])

    connect_options =
      [hostname: hostname]
      |> maybe_put_transport_opts(transport_opts)

    [connect_options: connect_options]
  end

  defp maybe_put_transport_opts(options, transport_opts)
       when is_list(transport_opts) and transport_opts != [],
       do: Keyword.put(options, :transport_opts, transport_opts)

  defp maybe_put_transport_opts(options, _transport_opts), do: options

  defp req_options do
    Config.get(:mini_apps_req_options, [])
  end

  defp limited_into_fun(max_bytes) do
    fn {:data, chunk}, {req, resp} ->
      chunk_size = IO.iodata_length(chunk)
      current = Req.Response.get_private(resp, :egregoros_mini_app_body_bytes, 0)
      new_size = current + chunk_size

      if new_size > max_bytes do
        resp =
          resp
          |> Req.Response.put_private(:egregoros_mini_app_body_bytes, new_size)
          |> Map.replace!(:body, {:error, :response_too_large})

        {:halt, {req, resp}}
      else
        resp =
          resp
          |> Req.Response.put_private(:egregoros_mini_app_body_bytes, new_size)
          |> Map.replace!(:body, resp.body <> IO.iodata_to_binary(chunk))

        {:cont, {req, resp}}
      end
    end
  end

  defp validate_status(200), do: :ok
  defp validate_status(status) when status in 300..399, do: {:error, :redirect_not_allowed}
  defp validate_status(status), do: {:error, {:unexpected_status, status}}

  defp validate_content_type(response, expected) when is_list(expected) do
    valid? =
      response
      |> Req.Response.get_header("content-type")
      |> Enum.any?(fn value ->
        value
        |> String.split(";", parts: 2)
        |> List.first()
        |> String.trim()
        |> String.downcase()
        |> then(&(&1 in expected))
      end)

    if valid?, do: :ok, else: {:error, :invalid_content_type}
  end
end
