defmodule EgregorosWeb.Plugs.SessionCookieDomainTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias EgregorosWeb.Plugs.Session

  test "uses a host-only HttpOnly cookie with an explicit root path" do
    conn = put_session_cookie(Session.options())

    assert [cookie] = get_resp_header(conn, "set-cookie")
    refute String.contains?(String.downcase(cookie), "domain=")
    assert String.contains?(String.downcase(cookie), "httponly")
    assert String.contains?(String.downcase(cookie), "path=/")
    assert String.contains?(String.downcase(cookie), "samesite=lax")
  end

  test "secure deployments use the __Host- prefix and Secure attribute" do
    options = Session.options(secure: true)
    conn = put_session_cookie(options)

    assert options[:key] == "__Host-egregoros"
    assert [cookie] = get_resp_header(conn, "set-cookie")
    assert String.starts_with?(cookie, "__Host-egregoros=")
    assert String.contains?(String.downcase(cookie), "secure")
    refute String.contains?(String.downcase(cookie), "domain=")
  end

  defp put_session_cookie(options) do
    secret_key_base = EgregorosWeb.Endpoint.config(:secret_key_base)

    conn(:get, "/")
    |> Map.put(:secret_key_base, secret_key_base)
    |> Plug.Session.call(Plug.Session.init(options))
    |> fetch_session()
    |> put_session(:user_id, 1)
    |> send_resp(200, "ok")
  end
end
