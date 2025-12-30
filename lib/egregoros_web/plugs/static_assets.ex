defmodule EgregorosWeb.Plugs.StaticAssets do
  @moduledoc false

  @behaviour Plug

  def init(opts) do
    Plug.Static.init(opts)
  end

  def call(%Plug.Conn{request_path: "/uploads" <> _rest} = conn, _opts) do
    conn
  end

  def call(conn, opts) do
    Plug.Static.call(conn, opts)
  end
end
