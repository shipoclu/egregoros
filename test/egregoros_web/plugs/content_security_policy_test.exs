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

  test "allows an exact validated OAuth callback origin without allowing its path" do
    conn =
      policy_conn()
      |> ContentSecurityPolicy.allow_form_action_redirect(
        "https://app.example:8443/oauth/callback?attempt=1"
      )

    [policy] = get_resp_header(conn, "content-security-policy")

    assert policy =~ "form-action 'self' https://app.example:8443"
    refute policy =~ "oauth/callback"
    refute policy =~ "attempt=1"
  end

  test "refuses non-HTTP and credentialed OAuth callback sources" do
    original = policy_conn()
    [original_policy] = get_resp_header(original, "content-security-policy")

    Enum.each(
      ["javascript:alert(1)", "https://user:password@app.example/callback", "//app.example/cb"],
      fn redirect_uri ->
        conn = ContentSecurityPolicy.allow_form_action_redirect(original, redirect_uri)
        assert get_resp_header(conn, "content-security-policy") == [original_policy]
      end
    )
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
