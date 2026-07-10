defmodule EgregorosWeb.Plugs.RateLimitInbox do
  import Plug.Conn

  alias Egregoros.RateLimiter
  alias EgregorosWeb.ClientIP

  @default_limit 120
  @default_interval_ms 10_000

  def init(opts), do: opts

  def call(conn, _opts) do
    {limit, interval_ms} = limits()
    key = rate_key(conn)

    case RateLimiter.allow?(:inbox, key, limit, interval_ms) do
      :ok ->
        conn

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(interval_ms, 1_000)))
        |> send_resp(429, "Too Many Requests")
        |> halt()
    end
  end

  defp limits do
    opts = Egregoros.Config.get(:rate_limit_inbox, [])

    limit =
      case Keyword.get(opts, :limit, @default_limit) do
        value when is_integer(value) and value >= 1 -> value
        _ -> @default_limit
      end

    interval_ms =
      case Keyword.get(opts, :interval_ms, @default_interval_ms) do
        value when is_integer(value) and value >= 1 -> value
        _ -> @default_interval_ms
      end

    {limit, interval_ms}
  end

  defp rate_key(conn) do
    ClientIP.address(conn) <> "|" <> conn.request_path
  end
end
