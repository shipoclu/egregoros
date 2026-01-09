defmodule EgregorosWeb.WebSock.Stub do
  @behaviour EgregorosWeb.WebSock

  @impl true
  def upgrade(%Plug.Conn{} = conn, _handler, _state, _opts) do
    %{conn | state: :upgraded}
  end
end

