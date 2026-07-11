defmodule EgregorosWeb.MiniAppAssetController do
  use EgregorosWeb, :controller

  alias Egregoros.MiniApps.Card
  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.Fetcher

  @image_content_types ~w(image/avif image/webp image/png image/jpeg image/gif)

  def image(conn, %{"card_id" => card_id, "resolution_token" => resolution_token}) do
    conn = no_store(conn)

    with %Card{image_url: image_url} when is_binary(image_url) and image_url != "" <-
           Cards.get_active_by_id(card_id, resolution_token),
         {:ok, %{body: body, headers: headers}} <- Fetcher.get(image_url, :asset),
         content_type when content_type in @image_content_types <- content_type(headers),
         true <- is_binary(body) do
      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(200, body)
    else
      nil -> send_resp(conn, 404, "Not found")
      %Card{} -> send_resp(conn, 404, "Not found")
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
  end

  defp content_type(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == "content-type", do: normalize_content_type(value)

      _ ->
        nil
    end)
  end

  defp content_type(headers) when is_map(headers) do
    headers
    |> Map.get("content-type")
    |> List.wrap()
    |> Enum.find_value(&normalize_content_type/1)
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
end
