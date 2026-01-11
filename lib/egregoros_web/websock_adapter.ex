defmodule EgregorosWeb.WebSockAdapter do
  @behaviour EgregorosWeb.WebSock

  @impl true
  def upgrade(conn, handler, state, opts) do
    WebSockAdapter.upgrade(conn, handler, state, opts)
  end
end
