defmodule Egregoros.Federation.ResponseValidator do
  @moduledoc false

  @activitystreams_profile "https://www.w3.org/ns/activitystreams"

  def validate_activitystreams(%{status: status}) when status not in 200..299, do: :ok

  def validate_activitystreams(%{status: status, headers: headers}) when status in 200..299 do
    headers
    |> header_values("content-type")
    |> Enum.any?(&activitystreams_content_type?/1)
    |> case do
      true -> :ok
      false -> {:error, :invalid_activitystreams_content_type}
    end
  end

  def validate_activitystreams(_response),
    do: {:error, :invalid_activitystreams_content_type}

  def validate_webfinger(%{status: status}) when status not in 200..299, do: :ok

  def validate_webfinger(%{status: status, headers: headers}) when status in 200..299 do
    headers
    |> header_values("content-type")
    |> Enum.any?(&webfinger_content_type?/1)
    |> case do
      true -> :ok
      false -> {:error, :invalid_webfinger_content_type}
    end
  end

  def validate_webfinger(_response), do: {:error, :invalid_webfinger_content_type}

  def activitystreams_media_type?(value) when is_binary(value) do
    [media_type | _parameters] = String.split(value, ";")
    media_type = media_type |> String.trim() |> String.downcase()
    value = String.downcase(value)

    case media_type do
      "application/activity+json" -> true
      "application/ld+json" -> String.contains?(value, @activitystreams_profile)
      _ -> false
    end
  end

  def activitystreams_media_type?(_value), do: false

  defp activitystreams_content_type?(value), do: activitystreams_media_type?(value)

  defp webfinger_content_type?(value) when is_binary(value) do
    value
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("application/jrd+json")
  end

  defp webfinger_content_type?(_value), do: false

  defp header_values(headers, name) when is_list(headers) do
    headers
    |> Enum.flat_map(fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == name, do: List.wrap(value), else: []

      _ ->
        []
    end)
  end

  defp header_values(headers, name) when is_map(headers) do
    headers
    |> Enum.flat_map(fn {key, value} ->
      if is_binary(key) and String.downcase(key) == name, do: List.wrap(value), else: []
    end)
  end

  defp header_values(_headers, _name), do: []
end
