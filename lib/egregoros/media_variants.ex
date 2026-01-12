defmodule Egregoros.MediaVariants do
  @moduledoc false

  @thumbnail_max_size 400
  @blurhash_thumbnail_size 32
  @thumbnail_suffix "-thumb.jpg"

  def thumbnail_max_size, do: @thumbnail_max_size
  def blurhash_thumbnail_size, do: @blurhash_thumbnail_size
  def thumbnail_suffix, do: @thumbnail_suffix
  def thumbnail_content_type, do: "image/jpeg"

  def thumbnail_url_path(url_path) when is_binary(url_path) do
    url_path = String.trim(url_path)

    case Path.extname(url_path) do
      "" ->
        url_path

      _ext ->
        Path.rootname(url_path) <> @thumbnail_suffix
    end
  end

  def thumbnail_filename(filename) when is_binary(filename) do
    filename = String.trim(filename)

    case Path.extname(filename) do
      "" -> filename <> @thumbnail_suffix
      _ext -> Path.rootname(filename) <> @thumbnail_suffix
    end
  end
end
