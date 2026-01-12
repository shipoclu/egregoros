defmodule Egregoros.MediaMeta do
  @moduledoc false

  alias Egregoros.MediaVariants

  @blurhash_components [x_components: 4, y_components: 3]

  def mastodon_meta(%Plug.Upload{} = upload) do
    {meta, _blurhash} = info(upload)
    meta
  end

  def blurhash(%Plug.Upload{} = upload) do
    {_meta, blurhash} = info(upload)
    blurhash
  end

  def info(%Plug.Upload{content_type: "image/" <> _, path: path})
      when is_binary(path) do
    with {:ok, image} <- Image.open(path),
         {:ok, thumb} <- Image.thumbnail(image, MediaVariants.thumbnail_max_size()) do
      {original_width, original_height, _} = Image.shape(image)
      {thumb_width, thumb_height, _} = Image.shape(thumb)

      meta = %{
        "original" => meta_entry(original_width, original_height),
        "small" => meta_entry(thumb_width, thumb_height)
      }

      blurhash = build_blurhash(image)

      {meta, blurhash}
    else
      _ -> {%{}, nil}
    end
  end

  def info(_), do: {%{}, nil}

  defp meta_entry(width, height) when is_integer(width) and is_integer(height) and height > 0 do
    aspect = width / height
    size = "#{width}x#{height}"
    %{"width" => width, "height" => height, "size" => size, "aspect" => aspect}
  end

  defp meta_entry(width, height) when is_integer(width) and is_integer(height) do
    size = "#{width}x#{height}"
    %{"width" => width, "height" => height, "size" => size, "aspect" => 0.0}
  end

  defp build_blurhash(image) do
    with {:ok, image} <- maybe_flatten(image),
         {:ok, thumb} <- Image.thumbnail(image, MediaVariants.blurhash_thumbnail_size()),
         {:ok, blurhash} <- Image.Blurhash.encode(thumb, @blurhash_components) do
      blurhash
    else
      _ -> nil
    end
  end

  defp maybe_flatten(image) do
    if Image.has_alpha?(image) do
      Image.flatten(image, background_color: :white)
    else
      {:ok, image}
    end
  end
end
