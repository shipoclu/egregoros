defmodule EgregorosWeb.Plugs.ContentSecurityPolicy do
  @behaviour Plug

  import Plug.Conn

  @policy [
            "default-src 'self'",
            "base-uri 'self'",
            "object-src 'none'",
            "frame-ancestors 'none'",
            "frame-src 'none'",
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

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    header =
      if Egregoros.Config.get(:csp_report_only, false) do
        "content-security-policy-report-only"
      else
        "content-security-policy"
      end

    put_resp_header(conn, header, @policy)
  end
end
