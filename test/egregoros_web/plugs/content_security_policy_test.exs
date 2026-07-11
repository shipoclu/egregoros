defmodule EgregorosWeb.Plugs.ContentSecurityPolicyTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias EgregorosWeb.Plugs.ContentSecurityPolicy

  setup do
    previous = Application.get_env(:egregoros, :mini_apps_enabled, false)
    on_exit(fn -> Application.put_env(:egregoros, :mini_apps_enabled, previous) end)
    :ok
  end

  test "denies every frame origin while mini apps are disabled" do
    Application.put_env(:egregoros, :mini_apps_enabled, false)

    policy = policy_header()

    assert policy =~ "frame-src 'none'"
    refute policy =~ "frame-src https:"
  end

  test "allows only the trusted same-origin broker when mini apps are enabled" do
    Application.put_env(:egregoros, :mini_apps_enabled, true)

    policy = policy_header()

    assert policy =~ "frame-src 'self'"
    refute policy =~ "frame-src https:"
    refute policy =~ "frame-src 'none'"
    assert policy =~ "object-src 'none'"
    assert policy =~ "frame-ancestors 'none'"
  end

  test "denies browser capabilities that mini apps may only access through the host" do
    conn = policy_conn()

    assert get_resp_header(conn, "permissions-policy") == [
             "camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=(), bluetooth=(), hid=(), midi=(), display-capture=()"
           ]
  end

  defp policy_header do
    conn = policy_conn()
    [policy] = get_resp_header(conn, "content-security-policy")
    policy
  end

  defp policy_conn do
    Egregoros.Config.with_impl(Egregoros.Config.Stub, fn ->
      ContentSecurityPolicy.call(conn(:get, "/"), [])
    end)
  end
end
