defmodule EgregorosWeb.Plugs.SessionCookieDomainTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Egregoros.RuntimeConfig
  alias EgregorosWeb.Plugs.Session

  test "does not set a Domain attribute by default" do
    RuntimeConfig.with(%{session_cookie_domain: nil}, fn ->
      secret_key_base = EgregorosWeb.Endpoint.config(:secret_key_base)

      conn =
        conn(:get, "/")
        |> Map.put(:secret_key_base, secret_key_base)
        |> Session.call([])
        |> fetch_session()
        |> put_session(:user_id, 1)
        |> send_resp(200, "ok")

      assert [cookie] = get_resp_header(conn, "set-cookie")
      refute String.contains?(cookie, "domain=")
    end)
  end

  test "sets a Domain attribute when configured" do
    RuntimeConfig.with(%{session_cookie_domain: "example.com"}, fn ->
      secret_key_base = EgregorosWeb.Endpoint.config(:secret_key_base)

      conn =
        conn(:get, "/")
        |> Map.put(:secret_key_base, secret_key_base)
        |> Session.call([])
        |> fetch_session()
        |> put_session(:user_id, 1)
        |> send_resp(200, "ok")

      assert [cookie] = get_resp_header(conn, "set-cookie")
      assert String.contains?(cookie, "domain=example.com")
    end)
  end
end
