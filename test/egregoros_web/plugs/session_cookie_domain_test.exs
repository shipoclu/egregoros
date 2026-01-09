defmodule EgregorosWeb.Plugs.SessionCookieDomainTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias EgregorosWeb.Plugs.Session

  test "does not set a Domain attribute by default" do
    original = Application.get_env(:egregoros, :session_cookie_domain)
    Application.delete_env(:egregoros, :session_cookie_domain)

    try do
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
    after
      restore_session_cookie_domain(original)
    end
  end

  test "sets a Domain attribute when configured" do
    original = Application.get_env(:egregoros, :session_cookie_domain)
    Application.put_env(:egregoros, :session_cookie_domain, "example.com")

    try do
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
    after
      restore_session_cookie_domain(original)
    end
  end

  defp restore_session_cookie_domain(nil) do
    Application.delete_env(:egregoros, :session_cookie_domain)
  end

  defp restore_session_cookie_domain(value) do
    Application.put_env(:egregoros, :session_cookie_domain, value)
  end
end
