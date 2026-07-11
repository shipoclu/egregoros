defmodule EgregorosWeb.MiniAppAssetController do
  use EgregorosWeb, :controller

  alias Egregoros.MiniApps
  alias Egregoros.MiniApps.Card
  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.Fetcher
  alias Egregoros.MiniApps.ImageSanitizer
  alias Egregoros.MiniApps.Origin
  alias Egregoros.RateLimiter
  alias EgregorosWeb.ClientIP

  @client_rate_limit 60
  @client_rate_interval_ms 60_000

  def image(conn, %{"card_id" => card_id, "resolution_token" => resolution_token}) do
    conn = no_store(conn)

    with :ok <- rate_limit(conn),
         %Card{app_origin: app_origin, image_url: image_url}
         when is_binary(app_origin) and is_binary(image_url) and image_url != "" <-
           Cards.get_active_by_id(card_id, resolution_token),
         :ok <- Origin.validate_url(image_url, app_origin),
         true <- origin_allowed?(app_origin),
         {:ok, %{body: body, headers: headers}} <- Fetcher.get(image_url, :asset),
         content_type when is_binary(content_type) <- content_type(headers),
         {:ok, %{body: safe_body, content_type: safe_content_type}} <-
           ImageSanitizer.sanitize(body, content_type),
         :ok <-
           authorize_response(card_id, resolution_token, app_origin, image_url) do
      conn
      |> put_resp_content_type(safe_content_type, nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cross-origin-resource-policy", "same-origin")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> send_resp(200, safe_body)
    else
      {:error, :rate_limited} -> send_resp(conn, 429, "Too many requests")
      nil -> send_resp(conn, 404, "Not found")
      %Card{} -> send_resp(conn, 404, "Not found")
      false -> send_resp(conn, 404, "Not found")
      {:error, :stale_card} -> send_resp(conn, 404, "Not found")
      _ -> send_resp(conn, 502, "Unable to load image")
    end
  end

  def image(conn, _params) do
    conn
    |> no_store()
    |> send_resp(404, "Not found")
  end

  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "private, no-store, max-age=0")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp content_type(headers) when is_list(headers) do
    headers
    |> Enum.flat_map(fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == "content-type", do: [value], else: []

      _header ->
        []
    end)
    |> one_content_type()
  end

  defp content_type(headers) when is_map(headers) do
    headers
    |> Map.get("content-type")
    |> List.wrap()
    |> one_content_type()
  end

  defp content_type(_headers), do: nil

  defp normalize_content_type(value) when is_binary(value) do
    value
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_content_type(_value), do: nil

  defp one_content_type([value]), do: normalize_content_type(value)
  defp one_content_type(_values), do: nil

  defp origin_allowed?(origin) do
    case URI.parse(origin) do
      %URI{host: domain} when is_binary(domain) -> MiniApps.domain_allowed?(domain)
      _uri -> false
    end
  end

  defp authorize_response(card_id, resolution_token, app_origin, image_url) do
    case Cards.get_active_by_id(card_id, resolution_token) do
      %Card{app_origin: ^app_origin, image_url: ^image_url} ->
        if origin_allowed?(app_origin), do: :ok, else: {:error, :stale_card}

      _card ->
        {:error, :stale_card}
    end
  end

  defp rate_limit(conn) do
    RateLimiter.allow?(
      :mini_app_asset_ip,
      ClientIP.address(conn),
      @client_rate_limit,
      @client_rate_interval_ms
    )
  end
end
