defmodule EgregorosWeb.MiniAppBrokerController do
  use EgregorosWeb, :controller

  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.Card
  alias Egregoros.PublicHostPolicy

  def show(conn, %{
        "card_id" => card_id,
        "launch_id" => launch_id,
        "resolution_token" => resolution_token
      }) do
    with true <- valid_launch_id?(launch_id),
         %Card{} = card <- Cards.get_active_by_id(card_id, resolution_token),
         false <- cookie_host_app?(card, conn.host) do
      nonce = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

      conn
      |> put_resp_header("content-security-policy", policy(card.app_origin, nonce))
      |> put_resp_header("cache-control", "private, no-store, max-age=0")
      |> put_resp_header("pragma", "no-cache")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type("text/html")
      |> send_resp(200, document(card, nonce))
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  def show(conn, _params), do: send_resp(conn, 404, "Not Found")

  defp valid_launch_id?(value) when is_binary(value),
    do: String.match?(value, ~r/^[A-Za-z0-9_-]{43}$/)

  defp valid_launch_id?(_value), do: false

  defp cookie_host_app?(%Card{app_origin: origin}, request_host) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) ->
        PublicHostPolicy.cookie_host?(host, request_host)

      _ ->
        true
    end
  end

  defp policy(app_origin, nonce) do
    [
      "default-src 'none'",
      "script-src 'self'",
      "style-src 'nonce-#{nonce}'",
      "frame-src #{app_origin}",
      "frame-ancestors 'self'",
      "base-uri 'none'",
      "form-action 'none'",
      "object-src 'none'",
      "connect-src 'none'",
      "img-src 'none'"
    ]
    |> Enum.join("; ")
    |> Kernel.<>(";")
  end

  defp document(card, nonce) do
    launch_url = escape(card.launch_url)
    app_origin = escape(card.app_origin)
    title = escape(card.app_name <> " mini app")

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="referrer" content="no-referrer">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>Mini app broker</title>
        <style nonce="#{nonce}">html,body,iframe{box-sizing:border-box;width:100%;height:100%;margin:0;border:0;overflow:hidden}body{background:white}</style>
      </head>
      <body>
        <iframe id="mini-app-frame" title="#{title}" src="#{launch_url}" data-app-origin="#{app_origin}" sandbox="allow-scripts allow-forms allow-same-origin" referrerpolicy="no-referrer" allow="camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'"></iframe>
        <script src="/assets/js/mini-app-frame-relay.js" defer></script>
      </body>
    </html>
    """
  end

  defp escape(value) do
    value
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
