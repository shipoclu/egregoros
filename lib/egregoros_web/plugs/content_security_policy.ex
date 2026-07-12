defmodule EgregorosWeb.Plugs.ContentSecurityPolicy do
  @behaviour Plug

  import Plug.Conn

  alias Egregoros.MiniApps.Origin

  @policy [
            "default-src 'self'",
            "base-uri 'self'",
            "object-src 'none'",
            "frame-ancestors 'none'",
            "frame-src __MINI_APP_FRAMES__",
            "form-action 'self'",
            "script-src 'self'",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' https: data: blob:",
            "media-src 'self' https: blob:",
            "font-src 'self' data:",
            "connect-src 'self' ws: wss:",
            "worker-src 'self' blob:",
            "manifest-src 'self'"
          ]
          |> Enum.join("; ")
          |> Kernel.<>(";")

  @permissions_policy [
                        "camera=()",
                        "microphone=()",
                        "geolocation=()",
                        "payment=()",
                        "usb=()",
                        "serial=()",
                        "bluetooth=()",
                        "hid=()",
                        "midi=()",
                        "display-capture=()"
                      ]
                      |> Enum.join(", ")

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    frame_sources = if Egregoros.MiniApps.enabled?(), do: "'self'", else: "'none'"
    policy = String.replace(@policy, "__MINI_APP_FRAMES__", frame_sources)

    header =
      if Egregoros.Config.get(:csp_report_only, false) do
        "content-security-policy-report-only"
      else
        "content-security-policy"
      end

    conn
    |> put_resp_header(header, policy)
    |> put_resp_header("permissions-policy", @permissions_policy)
  end

  def allow_form_action_redirect(conn, redirect_uri) do
    with {:ok, origin} <- Origin.from_url(redirect_uri) do
      Enum.reduce(
        ["content-security-policy", "content-security-policy-report-only"],
        conn,
        fn header, conn -> allow_form_action_origin(conn, header, origin) end
      )
    else
      _error -> conn
    end
  end

  defp allow_form_action_origin(conn, header, origin) do
    case get_resp_header(conn, header) do
      [policy] ->
        put_resp_header(
          conn,
          header,
          String.replace(
            policy,
            "form-action 'self'",
            "form-action 'self' #{origin}",
            global: false
          )
        )

      _other ->
        conn
    end
  end
end
