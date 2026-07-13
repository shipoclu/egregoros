defmodule EgregorosWeb.MiniAppAuthCompletionControllerTest do
  use EgregorosWeb.ConnCase, async: true

  test "serves a data-free, same-origin-only OAuth completion relay", %{conn: conn} do
    conn = get(conn, "/mini-apps/oauth/relay")

    assert html_response(conn, 200) =~
             ~s(src="/assets/js/mini-app-auth-completion-relay.js")

    refute conn.resp_body =~ "window.opener"
    refute conn.resp_body =~ "handoff_code"
    assert get_resp_header(conn, "cache-control") == ["private, no-store, max-age=0"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "cross-origin-opener-policy") == []
    assert get_resp_header(conn, "cross-origin-resource-policy") == ["same-origin"]

    [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "default-src 'none'"
    assert policy =~ "script-src 'self'"
    assert policy =~ "frame-ancestors 'none'"
    assert policy =~ "connect-src 'none'"
  end
end
