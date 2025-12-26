defmodule EgregorosWeb.Plugs.RequireScopesTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Mox

  alias EgregorosWeb.Plugs.RequireScopes

  setup :set_mox_from_context
  setup :verify_on_exit!

  test "returns 401 when unauthorized" do
    Egregoros.AuthZ.Mock
    |> expect(:authorize, fn _conn, ["read"] -> {:error, :unauthorized} end)

    conn = conn(:get, "/api/v1/accounts/verify_credentials") |> RequireScopes.call(["read"])

    assert conn.halted
    assert conn.status == 401
  end

  test "returns 403 when scope is insufficient" do
    Egregoros.AuthZ.Mock
    |> expect(:authorize, fn _conn, ["write"] -> {:error, :insufficient_scope} end)

    conn = conn(:post, "/api/v1/statuses") |> RequireScopes.call(["write"])

    assert conn.halted
    assert conn.status == 403
  end

  test "passes through when scopes are allowed" do
    Egregoros.AuthZ.Mock
    |> expect(:authorize, fn _conn, ["read"] -> :ok end)

    conn = conn(:get, "/api/v1/accounts/verify_credentials") |> RequireScopes.call(["read"])

    refute conn.halted
    assert is_nil(conn.status)
  end
end
