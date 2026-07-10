defmodule EgregorosWeb.Plugs.RateLimit do
  import Plug.Conn

  alias Egregoros.Config
  alias Egregoros.RateLimiter
  alias EgregorosWeb.ClientIP

  def init(opts) when is_list(opts) do
    Keyword.validate!(opts, [:bucket, :config_key, :limit, :interval_ms])
  end

  def call(conn, opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    {limit, interval_ms} = limits(opts)
    key = ClientIP.address(conn) <> "|" <> conn.request_path

    case RateLimiter.allow?(bucket, key, limit, interval_ms) do
      :ok ->
        conn

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(max(div(interval_ms, 1_000), 1)))
        |> send_resp(429, "Too Many Requests")
        |> halt()
    end
  end

  defp limits(opts) do
    config = Config.get(Keyword.fetch!(opts, :config_key), [])
    default_limit = Keyword.fetch!(opts, :limit)
    default_interval_ms = Keyword.fetch!(opts, :interval_ms)

    limit = positive_integer(Keyword.get(config, :limit), default_limit)
    interval_ms = positive_integer(Keyword.get(config, :interval_ms), default_interval_ms)
    node_count = positive_integer(Config.get(:rate_limit_node_count, 1), 1)

    {max(div(limit + node_count - 1, node_count), 1), interval_ms}
  end

  defp positive_integer(value, _default) when is_integer(value) and value >= 1, do: value
  defp positive_integer(_value, default), do: default
end
