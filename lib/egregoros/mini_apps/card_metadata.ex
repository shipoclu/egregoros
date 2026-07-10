defmodule Egregoros.MiniApps.CardMetadata do
  @moduledoc false

  alias Egregoros.MiniApps.Origin
  alias Egregoros.MiniApps.StrictJSON

  @max_bytes 32_768
  @allowed_fields ~w(version title imageUrl buttonTitle launchUrl)

  @enforce_keys [:version, :title, :image_url, :button_title, :launch_url]
  defstruct [:version, :title, :image_url, :button_title, :launch_url]

  def decode(data, page_url, app_origin)
      when is_binary(data) and is_binary(page_url) and is_binary(app_origin) do
    with {:ok, app_origin} <- Origin.parse_origin(app_origin),
         :ok <- Origin.validate_url(page_url, app_origin),
         {:ok, attrs} <-
           StrictJSON.decode(data, max_bytes: @max_bytes, too_large_error: :card_too_large),
         true <- is_map(attrs) or {:error, :invalid_card},
         :ok <- only_fields(attrs),
         "1" <- attrs["version"] || {:error, :unsupported_version},
         {:ok, title} <- bounded_string(attrs["title"], 1, 80, :invalid_title),
         {:ok, button_title} <-
           bounded_string(attrs["buttonTitle"], 1, 32, :invalid_button_title),
         {:ok, image_url} <- exact_origin_url(attrs["imageUrl"], app_origin),
         {:ok, launch_url} <- exact_origin_url(attrs["launchUrl"], app_origin) do
      {:ok,
       %__MODULE__{
         version: "1",
         title: title,
         image_url: image_url,
         button_title: button_title,
         launch_url: launch_url
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_card}
    end
  end

  def decode(_data, _page_url, _app_origin), do: {:error, :invalid_card}

  defp only_fields(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in @allowed_fields)),
      do: :ok,
      else: {:error, :unknown_field}
  end

  defp bounded_string(value, min, max, error) when is_binary(value) do
    size = String.length(value)

    if size in min..max and String.valid?(value) and String.trim(value) == value,
      do: {:ok, value},
      else: {:error, error}
  end

  defp bounded_string(_value, _min, _max, error), do: {:error, error}

  defp exact_origin_url(value, origin) when is_binary(value) do
    case Origin.validate_url(value, origin) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  defp exact_origin_url(_value, _origin), do: {:error, :invalid_url}
end
