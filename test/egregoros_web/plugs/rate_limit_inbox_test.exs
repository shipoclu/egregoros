defmodule EgregorosWeb.Plugs.RateLimitInboxTest do
  use ExUnit.Case, async: true

  import Mox
  import Plug.Conn
  import Plug.Test

  alias EgregorosWeb.Plugs.RateLimitInbox

  setup :set_mox_from_context
  setup :verify_on_exit!

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
end
