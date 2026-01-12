defmodule Egregoros.MediaStorage.Local do
  @behaviour Egregoros.MediaStorage

  alias Egregoros.MediaVariants

  @max_bytes 10_000_000

  @content_type_extensions %{
    "image/png" => ".png",
    "image/jpeg" => ".jpg",
    "image/webp" => ".webp",
    "image/gif" => ".gif",
    "image/heic" => ".heic",
    "image/heif" => ".heif",
    "video/mp4" => ".mp4",
    "video/webm" => ".webm",
    "video/quicktime" => ".mov",
    "audio/mpeg" => ".mp3",
    "audio/ogg" => ".ogg",
    "audio/opus" => ".opus",
    "audio/wav" => ".wav",
    "audio/aac" => ".aac",
    "audio/mp4" => ".m4a"
  }

  @impl true
  def store_media(user, %Plug.Upload{} = upload) do
    store_media(user, upload, uploads_root())
  end

  def store_media(%{id: user_id}, %Plug.Upload{} = upload, uploads_root)
      when is_integer(user_id) and is_binary(uploads_root) do
    with {:ok, ext} <- extension(upload),
         :ok <- validate_size(upload),
         {:ok, url_path} <- persist(upload, uploads_root, user_id, ext) do
      {:ok, url_path}
    end
  end

  defp uploads_root do
    priv_dir =
      :egregoros
      |> :code.priv_dir()
      |> to_string()

    default = Path.join([priv_dir, "static", "uploads"])

    Application.get_env(:egregoros, :uploads_dir, default)
  end

  defp validate_size(%Plug.Upload{path: path}) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_bytes -> :ok
      {:ok, _} -> {:error, :file_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extension(%Plug.Upload{content_type: content_type, filename: filename})
       when is_binary(content_type) and is_binary(filename) do
    case Map.fetch(@content_type_extensions, content_type) do
      {:ok, ext} -> {:ok, ext}
      :error -> {:error, :unsupported_media_type}
    end
  end

  defp persist(%Plug.Upload{path: path, content_type: content_type}, uploads_root, user_id, ext)
       when is_binary(path) and is_binary(uploads_root) and is_binary(content_type) do
    filename = "#{Ecto.UUID.generate()}#{ext}"
    relative_dir = Path.join(["uploads", "media", Integer.to_string(user_id)])
    relative_path = Path.join(relative_dir, filename)
    destination_dir = Path.join([uploads_root, "media", Integer.to_string(user_id)])
    destination_path = Path.join(destination_dir, filename)

    with :ok <- File.mkdir_p(destination_dir),
         :ok <- File.cp(path, destination_path) do
      _ = maybe_write_thumbnail(destination_path, destination_dir, filename, content_type)
      {:ok, "/" <> relative_path}
    end
  end

  defp maybe_write_thumbnail(source_path, destination_dir, filename, content_type)
       when is_binary(source_path) and is_binary(destination_dir) and is_binary(filename) and
              is_binary(content_type) do
    if String.starts_with?(content_type, "image/") do
      thumb_filename = MediaVariants.thumbnail_filename(filename)
      thumb_destination = Path.join(destination_dir, thumb_filename)
      thumbnail_max = MediaVariants.thumbnail_max_size()

      with {:ok, image} <- Image.open(source_path),
           {:ok, image} <- maybe_flatten(image),
           {:ok, thumb} <- Image.thumbnail(image, thumbnail_max),
           {:ok, _} <- Image.write(thumb, thumb_destination) do
        :ok
      else
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp maybe_write_thumbnail(_source_path, _destination_dir, _filename, _content_type), do: :ok

  defp maybe_flatten(image) do
    if Image.has_alpha?(image) do
      Image.flatten(image, background_color: :white)
    else
      {:ok, image}
    end
  end
end
