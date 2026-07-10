defmodule EgregorosWeb.Plugs.RateLimitInboxTest do
  use ExUnit.Case, async: true

  import Mox
  import Plug.Conn
  import Plug.Test

  alias EgregorosWeb.Plugs.RateLimitInbox

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Egregoros.Config.put_impl(Egregoros.Config.Mock)
    stub_with(Egregoros.Config.Mock, Egregoros.Config.Stub)
    :ok
  end

  test "rate limits inbox by IP even when Signature keyId is present" do
    Egregoros.RateLimiter.Mock
    |> expect(:allow?, fn :inbox, key, limit, interval_ms ->
      assert key == "9.9.9.9|/users/alice/inbox"
      assert limit == 120
      assert interval_ms == 10_000
      :ok
    end)

    conn =
      conn(:post, "/users/alice/inbox", "{}")
      |> put_req_header(
        "signature",
        "keyId=\"https://evil.example/users/evil#main-key\",signature=\"abc\""
      )
      |> Map.put(:remote_ip, {9, 9, 9, 9})

    conn = RateLimitInbox.call(conn, [])
    refute conn.halted
  end

  test "uses the forwarded client only when the direct proxy is trusted" do
    expect(Egregoros.Config.Mock, :get, 3, fn
      :rate_limit_inbox, [] -> []
      :trusted_proxies, [] -> ["10.0.0.0/8"]
      Egregoros.RateLimiter, Egregoros.RateLimiter.ETS -> Egregoros.RateLimiter.Mock
    end)

    expect(Egregoros.RateLimiter.Mock, :allow?, fn :inbox, key, _limit, _interval_ms ->
      assert key == "198.51.100.9|/inbox"
      :ok
    end)

    conn =
      conn(:post, "/inbox", "{}")
      |> put_req_header("x-forwarded-for", "198.51.100.9")
      |> Map.put(:remote_ip, {10, 0, 0, 2})

    conn = RateLimitInbox.call(conn, [])
    refute conn.halted
  end
end
