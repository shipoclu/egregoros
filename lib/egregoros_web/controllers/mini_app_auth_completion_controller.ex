defmodule EgregorosWeb.MiniAppAuthCompletionController do
  use EgregorosWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_header("content-security-policy", policy())
    |> put_resp_header("cache-control", "private, no-store, max-age=0")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cross-origin-resource-policy", "same-origin")
    |> put_resp_content_type("text/html")
    |> send_resp(200, document())
  end

  defp policy do
    [
      "default-src 'none'",
      "script-src 'self'",
      "frame-ancestors 'none'",
      "base-uri 'none'",
      "form-action 'none'",
      "object-src 'none'",
      "connect-src 'none'",
      "img-src 'none'",
      "style-src 'none'"
    ]
    |> Enum.join("; ")
    |> Kernel.<>(";")
  end

  defp document do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="referrer" content="no-referrer">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Authentication complete</title>
      </head>
      <body>
        <p>Authentication is complete. This window will close.</p>
        <script src="/assets/js/mini-app-auth-completion-relay.js" defer></script>
      </body>
    </html>
    """
  end
end
