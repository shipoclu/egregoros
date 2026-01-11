defmodule EgregorosWeb.Plugs.ForceSSLTest do
  use EgregorosWeb.ConnCase, async: true

  import Plug.Conn

  alias EgregorosWeb.Plugs.ForceSSL

  describe "force_ssl/2" do
    test "does not redirect when x-forwarded-proto is https" do
      conn =
        :get
        |> Plug.Test.conn("/live/websocket")
        |> put_req_header("x-forwarded-proto", "https")
        |> ForceSSL.call(ForceSSL.init([]))

      refute conn.halted
      assert conn.scheme == :https
      assert get_resp_header(conn, "strict-transport-security") != []
    end

    test "does not redirect when x-forwarded-proto is wss (traefik websocket)" do
      conn =
        :get
        |> Plug.Test.conn("/live/websocket")
        |> put_req_header("x-forwarded-proto", "wss")
        |> ForceSSL.call(ForceSSL.init([]))

      refute conn.halted
      assert conn.scheme == :https
    end

    test "parses comma-separated x-forwarded-proto values" do
      conn =
        :get
        |> Plug.Test.conn("/live/websocket")
        |> put_req_header("x-forwarded-proto", "https, wss")
        |> ForceSSL.call(ForceSSL.init([]))

      refute conn.halted
      assert conn.scheme == :https
    end

    test "redirects to https when x-forwarded-proto is missing" do
      conn =
        :get
        |> Plug.Test.conn("/live/websocket")
        |> ForceSSL.call(ForceSSL.init([]))

      assert conn.halted
      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["https://www.example.com/live/websocket"]
    end

    test "does not redirect excluded health checks" do
      conn =
        :get
        |> Plug.Test.conn("/health")
        |> ForceSSL.call(ForceSSL.init([]))

      refute conn.halted
    end
  end
end
