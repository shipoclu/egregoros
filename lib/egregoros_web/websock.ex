defmodule EgregorosWeb.WebSock do
  @callback upgrade(Plug.Conn.t(), module(), term(), keyword()) :: Plug.Conn.t()

  def upgrade(conn, handler, state, opts \\ []) do
    impl().upgrade(conn, handler, state, opts)
  end

  defp impl do
    Application.get_env(:egregoros, __MODULE__, EgregorosWeb.WebSockAdapter)
  end
end
