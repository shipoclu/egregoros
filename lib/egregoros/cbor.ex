defmodule Egregoros.CBOR do
  @moduledoc false

  import Bitwise

  @type decode_error ::
          :invalid_cbor
          | :truncated
          | :unsupported

  def decode(binary) when is_binary(binary) do
    case decode_term(binary) do
      {:ok, term, <<>>} -> {:ok, term}
      {:ok, _term, _rest} -> {:error, :invalid_cbor}
      {:error, _} = error -> error
    end
  end

  def decode(_), do: {:error, :invalid_cbor}

  def decode_next(binary) when is_binary(binary), do: decode_term(binary)
  def decode_next(_), do: {:error, :invalid_cbor}

  def encode(term), do: encode_term(term)

  defp decode_term(<<>>), do: {:error, :truncated}

  defp decode_term(<<initial, rest::binary>>) do
    major = initial >>> 5
    addl = initial &&& 0x1F

    with {:ok, value, rest} <- decode_value(major, addl, rest) do
      {:ok, value, rest}
    end
  end

  defp decode_value(0, addl, rest), do: decode_uint(addl, rest)

  defp decode_value(1, addl, rest) do
    with {:ok, n, rest} <- decode_uint(addl, rest) do
      {:ok, -1 - n, rest}
    end
  end

  defp decode_value(2, addl, rest), do: decode_bytes(addl, rest)
  defp decode_value(3, addl, rest), do: decode_text(addl, rest)
  defp decode_value(4, addl, rest), do: decode_array(addl, rest)
  defp decode_value(5, addl, rest), do: decode_map(addl, rest)

  defp decode_value(7, addl, rest) do
    case addl do
      20 -> {:ok, false, rest}
      21 -> {:ok, true, rest}
      22 -> {:ok, nil, rest}
      _ -> {:error, :unsupported}
    end
  end

  defp decode_value(_major, _addl, _rest), do: {:error, :unsupported}

  defp decode_uint(addl, rest) when addl < 24, do: {:ok, addl, rest}

  defp decode_uint(24, <<n, rest::binary>>), do: {:ok, n, rest}
  defp decode_uint(24, _rest), do: {:error, :truncated}

  defp decode_uint(25, <<n::16, rest::binary>>), do: {:ok, n, rest}
  defp decode_uint(25, _rest), do: {:error, :truncated}

  defp decode_uint(26, <<n::32, rest::binary>>), do: {:ok, n, rest}
  defp decode_uint(26, _rest), do: {:error, :truncated}

  defp decode_uint(27, <<n::64, rest::binary>>), do: {:ok, n, rest}
  defp decode_uint(27, _rest), do: {:error, :truncated}

  defp decode_uint(31, _rest), do: {:error, :unsupported}
  defp decode_uint(_addl, _rest), do: {:error, :invalid_cbor}

  defp decode_bytes(31, _rest), do: {:error, :unsupported}

  defp decode_bytes(addl, rest) do
    with {:ok, len, rest} <- decode_uint(addl, rest),
         true <- byte_size(rest) >= len do
      <<value::binary-size(len), rest::binary>> = rest
      {:ok, value, rest}
    else
      false -> {:error, :truncated}
      {:error, _} = error -> error
    end
  end

  defp decode_text(31, _rest), do: {:error, :unsupported}

  defp decode_text(addl, rest) do
    decode_bytes(addl, rest)
  end

  defp decode_array(31, _rest), do: {:error, :unsupported}

  defp decode_array(addl, rest) do
    with {:ok, len, rest} <- decode_uint(addl, rest) do
      decode_array_items(len, rest, [])
    end
  end

  defp decode_array_items(0, rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_array_items(len, rest, acc) when len > 0 do
    with {:ok, item, rest} <- decode_term(rest) do
      decode_array_items(len - 1, rest, [item | acc])
    end
  end

  defp decode_map(31, _rest), do: {:error, :unsupported}

  defp decode_map(addl, rest) do
    with {:ok, len, rest} <- decode_uint(addl, rest) do
      decode_map_pairs(len, rest, %{})
    end
  end

  defp decode_map_pairs(0, rest, acc), do: {:ok, acc, rest}

  defp decode_map_pairs(len, rest, acc) when len > 0 do
    with {:ok, key, rest} <- decode_term(rest),
         {:ok, value, rest} <- decode_term(rest) do
      decode_map_pairs(len - 1, rest, Map.put(acc, key, value))
    end
  end

  defp encode_term(nil), do: <<0xF6>>
  defp encode_term(true), do: <<0xF5>>
  defp encode_term(false), do: <<0xF4>>

  defp encode_term(int) when is_integer(int) and int >= 0 do
    encode_major_uint(0, int)
  end

  defp encode_term(int) when is_integer(int) and int < 0 do
    encode_major_uint(1, -1 - int)
  end

  defp encode_term(binary) when is_binary(binary) do
    if printable_utf8?(binary) do
      encode_major_bytes(3, binary)
    else
      encode_major_bytes(2, binary)
    end
  end

  defp encode_term(list) when is_list(list) do
    header = encode_major_uint(4, length(list))
    Enum.reduce(list, header, fn item, acc -> acc <> encode_term(item) end)
  end

  defp encode_term(%{} = map) do
    header = encode_major_uint(5, map_size(map))

    Enum.reduce(map, header, fn {key, value}, acc ->
      key_encoded =
        case key do
          k when is_binary(k) -> encode_major_bytes(3, k)
          _ -> encode_term(key)
        end

      acc <> key_encoded <> encode_term(value)
    end)
  end

  defp encode_term(_), do: raise(ArgumentError, "unsupported CBOR term")

  defp encode_major_bytes(major, binary) when is_integer(major) and is_binary(binary) do
    encode_major_uint(major, byte_size(binary)) <> binary
  end

  defp encode_major_uint(major, value)
       when is_integer(major) and is_integer(value) and value < 24 do
    <<(major <<< 5) + value>>
  end

  defp encode_major_uint(major, value)
       when is_integer(major) and is_integer(value) and value < 256 do
    <<(major <<< 5) + 24, value>>
  end

  defp encode_major_uint(major, value)
       when is_integer(major) and is_integer(value) and value < 65_536 do
    <<(major <<< 5) + 25, value::16>>
  end

  defp encode_major_uint(major, value)
       when is_integer(major) and is_integer(value) and value < 4_294_967_296 do
    <<(major <<< 5) + 26, value::32>>
  end

  defp encode_major_uint(major, value) when is_integer(major) and is_integer(value) do
    <<(major <<< 5) + 27, value::64>>
  end

  defp printable_utf8?(binary) when is_binary(binary) do
    case String.valid?(binary) do
      false -> false
      true -> String.printable?(binary)
    end
  end
end
