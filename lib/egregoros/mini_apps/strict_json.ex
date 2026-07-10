defmodule Egregoros.MiniApps.StrictJSON do
  @moduledoc false

  alias Jason.OrderedObject

  @max_depth 16

  def decode(data, opts \\ [])

  def decode(data, opts) when is_binary(data) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, 65_536)
    too_large_error = Keyword.get(opts, :too_large_error, :json_too_large)

    if byte_size(data) > max_bytes do
      {:error, too_large_error}
    else
      with {:ok, decoded} <- Jason.decode(data, objects: :ordered_objects),
           {:ok, value} <- normalize(decoded, 0) do
        {:ok, value}
      else
        {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
        {:error, _reason} = error -> error
      end
    end
  end

  def decode(_data, _opts), do: {:error, :invalid_json}

  defp normalize(_value, depth) when depth > @max_depth, do: {:error, :json_too_deep}

  defp normalize(%OrderedObject{values: values}, depth) do
    keys = Enum.map(values, &elem(&1, 0))

    if length(keys) != MapSet.size(MapSet.new(keys)) do
      {:error, :duplicate_json_key}
    else
      Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case normalize(value, depth + 1) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp normalize(values, depth) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize(value, depth + 1) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize(value, _depth)
       when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_nil(value),
       do: {:ok, value}

  defp normalize(_value, _depth), do: {:error, :invalid_json}
end
