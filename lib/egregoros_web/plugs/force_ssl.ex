defmodule EgregorosWeb.Plugs.ForceSSL do
  @behaviour Plug

  import Plug.Conn

  @default_exclude [
    hosts: ["localhost", "127.0.0.1"],
    paths: ["/health"]
  ]

  @default_hsts "max-age=31536000; includeSubDomains"

  @impl true
  def init(opts) do
    exclude = Keyword.get(opts, :exclude, @default_exclude)
    hsts = Keyword.get(opts, :hsts, true)
    %{exclude: exclude, hsts: hsts}
  end

  @impl true
  def call(conn, %{exclude: exclude, hsts: hsts}) do
    conn = rewrite_forwarded_scheme(conn)

    cond do
      excluded?(conn, exclude) ->
        conn

      conn.scheme == :https ->
        maybe_put_hsts(conn, hsts)

      true ->
        redirect_to_https(conn)
    end
  end

  defp rewrite_forwarded_scheme(conn) do
    forwarded_proto =
      conn
      |> get_req_header("x-forwarded-proto")
      |> normalize_forwarded_proto()

    case forwarded_proto do
      "https" -> %{conn | scheme: :https}
      "http" -> %{conn | scheme: :http}
      _ -> conn
    end
  end

  defp normalize_forwarded_proto([]), do: nil

  defp normalize_forwarded_proto(values) when is_list(values) do
    values
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> case do
      nil -> nil
      proto -> normalize_proto(proto)
    end
  end

  defp normalize_proto(proto) when is_binary(proto) do
    proto =
      proto
      |> String.downcase()
      |> String.trim()

    case proto do
      "wss" -> "https"
      "ws" -> "http"
      other -> other
    end
  end

  defp excluded?(conn, list) when is_list(list) do
    Enum.any?(list, fn
      {:hosts, hosts} -> conn.host in hosts
      {:paths, paths} -> conn.request_path in paths
      other -> raise ArgumentError, "unsupported :exclude entry: #{inspect(other)}"
    end)
  end

  defp maybe_put_hsts(conn, true), do: put_resp_header(conn, "strict-transport-security", @default_hsts)
  defp maybe_put_hsts(conn, false), do: conn

  defp redirect_to_https(conn) do
    status = if conn.method in ~w(HEAD GET), do: 301, else: 307
    location = "https://" <> conn.host <> conn.request_path <> qs(conn.query_string)

    conn
    |> put_resp_header("location", location)
    |> send_resp(status, "")
    |> halt()
  end

  defp qs(""), do: ""
  defp qs(qs), do: "?" <> qs
end

