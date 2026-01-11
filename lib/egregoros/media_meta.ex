defmodule Egregoros.MediaMeta do
  @moduledoc false

  def mastodon_meta(%Plug.Upload{content_type: "image/" <> _, path: path})
      when is_binary(path) do
    case image_dimensions(path) do
      {:ok, width, height} when is_integer(width) and is_integer(height) and height > 0 ->
        aspect = width / height
        size = "#{width}x#{height}"

        %{
          "original" => %{"width" => width, "height" => height, "size" => size, "aspect" => aspect},
          "small" => %{"width" => width, "height" => height, "size" => size, "aspect" => aspect}
        }

      _ ->
        %{}
    end
  end

  def mastodon_meta(_), do: %{}

  defp image_dimensions(path) when is_binary(path) do
    with {:ok, data} <- File.read(path) do
      image_dimensions_bin(data)
    end
  end

  defp image_dimensions_bin(
         <<137, 80, 78, 71, 13, 10, 26, 10, _length::32, "IHDR", width::32, height::32,
           _rest::binary>>
       )
       when width > 0 and height > 0 do
    {:ok, width, height}
  end

  defp image_dimensions_bin(<<"GIF87a", width::little-16, height::little-16, _rest::binary>>)
       when width > 0 and height > 0 do
    {:ok, width, height}
  end

  defp image_dimensions_bin(<<"GIF89a", width::little-16, height::little-16, _rest::binary>>)
       when width > 0 and height > 0 do
    {:ok, width, height}
  end

  defp image_dimensions_bin(<<"RIFF", _size::little-32, "WEBP", rest::binary>>) do
    webp_dimensions(rest)
  end

  defp image_dimensions_bin(<<0xFF, 0xD8, rest::binary>>) do
    jpeg_dimensions(rest)
  end

  defp image_dimensions_bin(_), do: {:error, :unknown_format}

  defp webp_dimensions(<<"VP8X", _chunk_size::little-32, _flags::8, _reserved::binary-3,
                       width_minus_one::little-unsigned-integer-size(24),
                       height_minus_one::little-unsigned-integer-size(24), _rest::binary>>)
       when width_minus_one >= 0 and height_minus_one >= 0 do
    {:ok, width_minus_one + 1, height_minus_one + 1}
  end

  defp webp_dimensions(<<"VP8 ", _chunk_size::little-32, _frame_tag::binary-3, 0x9D, 0x01, 0x2A,
                       width_raw::little-16, height_raw::little-16, _rest::binary>>) do
    width = Bitwise.band(width_raw, 0x3FFF)
    height = Bitwise.band(height_raw, 0x3FFF)

    if width > 0 and height > 0, do: {:ok, width, height}, else: {:error, :invalid_webp}
  end

  defp webp_dimensions(<<"VP8L", _chunk_size::little-32, 0x2F, packed::little-unsigned-32,
                       _rest::binary>>) do
    width = Bitwise.band(packed, 0x3FFF) + 1
    height = Bitwise.band(Bitwise.bsr(packed, 14), 0x3FFF) + 1

    if width > 0 and height > 0, do: {:ok, width, height}, else: {:error, :invalid_webp}
  end

  defp webp_dimensions(_), do: {:error, :invalid_webp}

  defp jpeg_dimensions(binary) when is_binary(binary) do
    parse_jpeg_segments(binary)
  end

  defp parse_jpeg_segments(<<>>), do: {:error, :invalid_jpeg}

  defp parse_jpeg_segments(<<0xFF, 0xFF, rest::binary>>) do
    parse_jpeg_segments(<<0xFF, rest::binary>>)
  end

  defp parse_jpeg_segments(<<0xFF, marker, rest::binary>>) do
    cond do
      marker in [0xD9, 0xDA] ->
        {:error, :invalid_jpeg}

      marker in [0xD8, 0x01] or (marker >= 0xD0 and marker <= 0xD7) ->
        parse_jpeg_segments(rest)

      true ->
        parse_jpeg_segment(marker, rest)
    end
  end

  defp parse_jpeg_segments(_), do: {:error, :invalid_jpeg}

  defp parse_jpeg_segment(marker, <<len::16, rest::binary>>) when len >= 2 do
    segment_len = len - 2

    if byte_size(rest) < segment_len do
      {:error, :invalid_jpeg}
    else
      <<segment::binary-size(segment_len), remaining::binary>> = rest

      if sof_marker?(marker) do
        parse_jpeg_sof(segment)
      else
        parse_jpeg_segments(remaining)
      end
    end
  end

  defp parse_jpeg_segment(_marker, _rest), do: {:error, :invalid_jpeg}

  defp sof_marker?(marker) when is_integer(marker) do
    marker in [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
  end

  defp parse_jpeg_sof(<<_precision::8, height::16, width::16, _rest::binary>>)
       when width > 0 and height > 0 do
    {:ok, width, height}
  end

  defp parse_jpeg_sof(_), do: {:error, :invalid_jpeg}
end
