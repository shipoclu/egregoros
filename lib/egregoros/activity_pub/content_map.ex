defmodule Egregoros.ActivityPub.ContentMap do
  @moduledoc false

  def normalize(%{} = object) do
    object
    |> maybe_copy_from_content_map()
  end

  def normalize(object), do: object

  defp maybe_copy_from_content_map(%{"content" => content} = object) when is_binary(content) do
    if String.trim(content) == "" do
      do_normalize(object)
    else
      object
    end
  end

  defp maybe_copy_from_content_map(object), do: do_normalize(object)

  defp do_normalize(%{"contentMap" => content_map} = object) when is_map(content_map) do
    case content_from_map(content_map) do
      content when is_binary(content) -> Map.put(object, "content", content)
      _ -> object
    end
  end

  defp do_normalize(object), do: object

  defp content_from_map(%{} = content_map) do
    preferred = ["en", "und"]

    Enum.find_value(preferred, fn key ->
      case Map.get(content_map, key) do
        "" <> _ = content ->
          content = String.trim(content)
          if content != "", do: content

        _ ->
          nil
      end
    end) ||
      content_map
      |> Enum.filter(fn {key, content} -> is_binary(key) and is_binary(content) end)
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.find_value(fn {_key, content} ->
        content = String.trim(content)
        if content != "", do: content
      end)
  end

  defp content_from_map(_content_map), do: nil
end
