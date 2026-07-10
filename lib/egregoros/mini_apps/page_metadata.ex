defmodule Egregoros.MiniApps.PageMetadata do
  @moduledoc false

  @max_page_bytes 1_000_000
  @metadata_name "fediverse:miniapp"

  def extract(html) when is_binary(html) and byte_size(html) <= @max_page_bytes do
    with true <- String.valid?(html),
         {:ok, tree} <- FastSanitize.Fragment.to_tree(html) do
      case find_metadata(tree) do
        [] -> {:ok, nil}
        [nil] -> {:error, :invalid_card_metadata}
        [content] when is_binary(content) -> {:ok, content}
        [_first | _rest] -> {:error, :duplicate_card_metadata}
      end
    else
      _ -> {:error, :invalid_page}
    end
  rescue
    _ -> {:error, :invalid_page}
  catch
    _, _ -> {:error, :invalid_page}
  end

  def extract(html) when is_binary(html), do: {:error, :page_too_large}
  def extract(_html), do: {:error, :invalid_page}

  defp find_metadata(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &find_metadata/1)

  defp find_metadata({:meta, attributes, children}) do
    current =
      if attribute(attributes, "name") == @metadata_name do
        [attribute(attributes, "content")]
      else
        []
      end

    current ++ find_metadata(children)
  end

  defp find_metadata({_tag, _attributes, children}), do: find_metadata(children)
  defp find_metadata(_node), do: []

  defp attribute(attributes, name) when is_list(attributes) do
    case Enum.find(attributes, fn
           {key, _value} -> to_string(key) == name
           _ -> false
         end) do
      {_key, value} -> value
      _ -> nil
    end
  end

  defp attribute(_attributes, _name), do: nil
end
