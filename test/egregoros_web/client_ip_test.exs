defmodule EgregorosWeb.ClientIPTest do
  use ExUnit.Case, async: true

  import Mox
  import Plug.Test

  alias EgregorosWeb.ClientIP

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Egregoros.Config.put_impl(Egregoros.Config.Mock)
    on_exit(&Egregoros.Config.clear_impl/0)
    :ok
  end

  test "ignores forwarded addresses from an untrusted peer" do
    expect(Egregoros.Config.Mock, :get, fn :trusted_proxies, [] -> ["10.0.0.0/8"] end)

    conn =
      conn(:get, "/")
      |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.7")
      |> Map.put(:remote_ip, {203, 0, 113, 9})

    assert ClientIP.address(conn) == "203.0.113.9"
  end

  test "uses the first untrusted address before trusted proxies" do
    expect(Egregoros.Config.Mock, :get, fn :trusted_proxies, [] ->
      ["10.0.0.0/8", "192.0.2.10"]
    end)

    conn =
      conn(:get, "/")
      |> Plug.Conn.put_req_header(
        "x-forwarded-for",
        "198.51.100.7, 10.1.2.3"
      )
      |> Map.put(:remote_ip, {192, 0, 2, 10})

    assert ClientIP.address(conn) == "198.51.100.7"
  end

  test "supports trusted IPv6 CIDR ranges" do
    expect(Egregoros.Config.Mock, :get, fn :trusted_proxies, [] -> ["2001:db8::/32"] end)

    conn =
      conn(:get, "/")
      |> Plug.Conn.put_req_header("x-forwarded-for", "2001:4860:4860::8888")
      |> Map.put(:remote_ip, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})

    assert ClientIP.address(conn) == "2001:4860:4860::8888"
  end
end
