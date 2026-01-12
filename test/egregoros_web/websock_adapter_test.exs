defmodule EgregorosWeb.WebSockAdapterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias EgregorosWeb.WebSockAdapter

  defmodule TestSock do
    @behaviour WebSock

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_in(_message, state), do: {:ok, state}

    @impl true
    def handle_info(_message, state), do: {:ok, state}
  end

  test "upgrade/4 delegates to WebSockAdapter.upgrade/4" do
    conn = conn(:get, "/live/websocket")
    conn = WebSockAdapter.upgrade(conn, TestSock, %{any: :state}, early_validate_upgrade: false)

    assert conn.state == :upgraded
  end
end
