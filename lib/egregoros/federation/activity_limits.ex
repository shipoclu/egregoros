defmodule Egregoros.Federation.ActivityLimits do
  @moduledoc """
  Structural limits applied to each remote ActivityPub object before persistence.

  Limits are reject-only: oversized structures are never silently truncated.
  """

  @max_recipients 100
  @max_tags 100
  @max_attachments 16
  @max_collection_items 200
  @max_list_items 500
  @max_depth 20
  @max_nodes 2_000

  @recipient_keys ~w(to cc bto bcc audience)
  @collection_keys ~w(items orderedItems)

  def validate(%{} = activity) do
    case walk(activity, 0, initial_counts()) do
      {:ok, _counts} -> :ok
      {:error, :activity_structure_limit} = error -> error
    end
  end

  def validate(_activity), do: {:error, :activity_structure_limit}

  defp walk(_value, depth, _counts) when depth > @max_depth,
    do: {:error, :activity_structure_limit}

  defp walk(%{} = map, depth, counts) do
    with {:ok, counts} <- increment(counts, :nodes, 1, @max_nodes),
         {:ok, counts} <- count_map_fields(map, counts) do
      Enum.reduce_while(Map.values(map), {:ok, counts}, fn value, {:ok, acc} ->
        case walk(value, depth + 1, acc) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp walk(list, _depth, _counts) when is_list(list) and length(list) > @max_list_items,
    do: {:error, :activity_structure_limit}

  defp walk(list, depth, counts) when is_list(list) do
    with {:ok, counts} <- increment(counts, :nodes, 1, @max_nodes) do
      Enum.reduce_while(list, {:ok, counts}, fn value, {:ok, acc} ->
        case walk(value, depth + 1, acc) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp walk(_scalar, _depth, counts), do: {:ok, counts}

  defp count_map_fields(map, counts) do
    with {:ok, counts} <-
           increment(
             counts,
             :recipients,
             field_count(map, @recipient_keys),
             @max_recipients
           ),
         {:ok, counts} <- increment(counts, :tags, field_count(map, ["tag"]), @max_tags),
         {:ok, counts} <-
           increment(
             counts,
             :attachments,
             field_count(map, ["attachment"]),
             @max_attachments
           ),
         {:ok, counts} <-
           increment(
             counts,
             :collection_items,
             field_count(map, @collection_keys),
             @max_collection_items
           ) do
      {:ok, counts}
    end
  end

  defp field_count(map, keys) do
    Enum.reduce(keys, 0, fn key, total ->
      case Map.get(map, key) do
        nil -> total
        value when is_list(value) -> total + length(value)
        _value -> total + 1
      end
    end)
  end

  defp increment(counts, key, amount, maximum) do
    value = Map.fetch!(counts, key) + amount

    if value <= maximum,
      do: {:ok, Map.put(counts, key, value)},
      else: {:error, :activity_structure_limit}
  end

  defp initial_counts do
    %{recipients: 0, tags: 0, attachments: 0, collection_items: 0, nodes: 0}
  end
end
