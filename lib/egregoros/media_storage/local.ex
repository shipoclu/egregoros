defmodule Egregoros.MediaStorage.Local do
  @behaviour Egregoros.MediaStorage

  import Bitwise

  alias Egregoros.MediaVariants

  @max_bytes 10_000_000
  @max_dimension 16_384
  @max_pixels 40_000_000
  @max_frames 100
  @processing_timeout_ms 10_000

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
      when is_binary(user_id) and is_binary(uploads_root) do
    with :ok <- validate_size(upload),
         {:ok, ext} <- extension(upload.content_type),
         {:ok, detected_type} <- detect_media_type(upload.path),
         :ok <- validate_declared_type(upload.content_type, detected_type),
         :ok <- validate_image_if_needed(upload.path, detected_type),
         {:ok, url_path} <-
           persist(upload, uploads_root, user_id, ext, detected_type) do
      {:ok, url_path}
    end
  end

  defp uploads_root do
    priv_dir =
      :egregoros
      |> :code.priv_dir()
      |> to_string()

    default = Path.join([priv_dir, "static", "uploads"])

    Egregoros.Config.get(:uploads_dir, default)
  end

  defp validate_size(%Plug.Upload{path: path}) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_bytes -> :ok
      {:ok, _} -> {:error, :file_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extension(content_type) when is_binary(content_type) do
    case Map.fetch(@content_type_extensions, content_type) do
      {:ok, ext} -> {:ok, ext}
      :error -> {:error, :unsupported_media_type}
    end
  end

  defp extension(_content_type), do: {:error, :unsupported_media_type}

  defp persist(%Plug.Upload{path: path}, uploads_root, user_id, ext, detected_type)
       when is_binary(path) and is_binary(uploads_root) do
    filename = "#{Ecto.UUID.generate()}#{ext}"
    relative_dir = Path.join(["uploads", "media", user_id])
    relative_path = Path.join(relative_dir, filename)
    destination_dir = Path.join([uploads_root, "media", user_id])
    destination_path = Path.join(destination_dir, filename)

    with :ok <- File.mkdir_p(destination_dir),
         :ok <- File.cp(path, destination_path),
         :ok <-
           maybe_write_thumbnail(
             destination_path,
             destination_dir,
             filename,
             detected_type
           ) do
      {:ok, "/" <> relative_path}
    else
      {:error, reason} ->
        cleanup_failed_persist(destination_path, destination_dir, filename)
        {:error, reason}
    end
  end

  defp maybe_write_thumbnail(source_path, destination_dir, filename, detected_type)
       when is_binary(source_path) and is_binary(destination_dir) and is_binary(filename) and
              is_atom(detected_type) do
    if image_type?(detected_type) do
      thumb_filename = MediaVariants.thumbnail_filename(filename)
      thumb_destination = Path.join(destination_dir, thumb_filename)
      thumbnail_max = MediaVariants.thumbnail_max_size()

      run_image_task(fn ->
        with {:ok, image} <- Image.open(source_path),
             :ok <- validate_image_limits(image),
             {:ok, image} <- maybe_flatten(image),
             {:ok, thumb} <- Image.thumbnail(image, thumbnail_max),
             {:ok, _} <- Image.write(thumb, thumb_destination) do
          :ok
        else
          {:error, _reason} -> {:error, :invalid_media}
          _ -> {:error, :invalid_media}
        end
      end)
    else
      :ok
    end
  end

  defp maybe_write_thumbnail(_source_path, _destination_dir, _filename, _detected_type), do: :ok

  defp validate_image_if_needed(path, detected_type) do
    if image_type?(detected_type) do
      run_image_task(fn ->
        with {:ok, image} <- Image.open(path) do
          validate_image_limits(image)
        else
          _ -> {:error, :invalid_media}
        end
      end)
    else
      :ok
    end
  end

  defp validate_image_limits(image) do
    {width, height, _bands} = Image.shape(image)
    pages = Image.pages(image)

    cond do
      width > @max_dimension or height > @max_dimension ->
        {:error, :image_dimensions_too_large}

      pages > @max_frames ->
        {:error, :too_many_frames}

      width * height * pages > @max_pixels ->
        {:error, :image_pixel_count_too_large}

      true ->
        :ok
    end
  end

  defp run_image_task(fun) when is_function(fun, 0) do
    task = Task.Supervisor.async_nolink(Egregoros.MediaTaskSupervisor, fun)

    case Task.yield(task, @processing_timeout_ms) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :invalid_media}
      nil -> {:error, :media_processing_timeout}
    end
  catch
    :exit, _reason -> {:error, :media_processing_unavailable}
  end

  defp detect_media_type(path) when is_binary(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]),
         result <- :file.read(file, 64),
         :ok <- File.close(file),
         {:ok, bytes} <- normalize_read(result) do
      detect_bytes(bytes)
    end
  end

  defp normalize_read({:ok, bytes}) when is_binary(bytes) and byte_size(bytes) > 0,
    do: {:ok, bytes}

  defp normalize_read(_result), do: {:error, :invalid_media}

  defp detect_bytes(<<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>), do: {:ok, :png}
  defp detect_bytes(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, :jpeg}
  defp detect_bytes(<<"GIF87a", _::binary>>), do: {:ok, :gif}
  defp detect_bytes(<<"GIF89a", _::binary>>), do: {:ok, :gif}

  defp detect_bytes(<<_::binary-size(4), "ftyp", brand::binary-size(4), _::binary>>)
       when brand in ["heic", "heix", "hevc", "hevx", "mif1", "msf1"],
       do: {:ok, :heif}

  defp detect_bytes(<<_::binary-size(4), "ftyp", "qt  ", _::binary>>), do: {:ok, :quicktime}

  defp detect_bytes(<<_::binary-size(4), "ftyp", _brand::binary-size(4), _::binary>>),
    do: {:ok, :mp4}

  defp detect_bytes(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, :webp}
  defp detect_bytes(<<"RIFF", _::binary-size(4), "WAVE", _::binary>>), do: {:ok, :wav}
  defp detect_bytes(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: {:ok, :webm}
  defp detect_bytes(<<"OggS", _::binary>>), do: {:ok, :ogg}
  defp detect_bytes(<<"ID3", _::binary>>), do: {:ok, :mp3}

  defp detect_bytes(<<0xFF, second, _::binary>>) when (second &&& 0xF6) == 0xF0,
    do: {:ok, :aac}

  defp detect_bytes(<<0xFF, second, _::binary>>) when (second &&& 0xE0) == 0xE0,
    do: {:ok, :mp3}

  defp detect_bytes(_bytes), do: {:error, :invalid_media}

  defp validate_declared_type("image/png", :png), do: :ok
  defp validate_declared_type("image/jpeg", :jpeg), do: :ok
  defp validate_declared_type("image/gif", :gif), do: :ok
  defp validate_declared_type("image/webp", :webp), do: :ok
  defp validate_declared_type(type, :heif) when type in ["image/heic", "image/heif"], do: :ok
  defp validate_declared_type("video/quicktime", :quicktime), do: :ok
  defp validate_declared_type(type, :mp4) when type in ["video/mp4", "audio/mp4"], do: :ok
  defp validate_declared_type("video/webm", :webm), do: :ok
  defp validate_declared_type(type, :ogg) when type in ["audio/ogg", "audio/opus"], do: :ok
  defp validate_declared_type("audio/mpeg", :mp3), do: :ok
  defp validate_declared_type("audio/wav", :wav), do: :ok
  defp validate_declared_type("audio/aac", :aac), do: :ok
  defp validate_declared_type(_declared, _detected), do: {:error, :content_type_mismatch}

  defp image_type?(type), do: type in [:png, :jpeg, :gif, :webp, :heif]

  defp cleanup_failed_persist(destination_path, destination_dir, filename) do
    _ = File.rm(destination_path)
    _ = File.rm(Path.join(destination_dir, MediaVariants.thumbnail_filename(filename)))
    _ = File.rmdir(destination_dir)
    :ok
  end

  defp maybe_flatten(image) do
    if Image.has_alpha?(image) do
      Image.flatten(image, background_color: :white)
    else
      {:ok, image}
    end
  end
end
