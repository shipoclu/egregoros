defmodule Egregoros.MediaStorage.LocalTest do
  use ExUnit.Case, async: true

  alias Egregoros.MediaStorage.Local

  defp uploads_root do
    Path.join(["tmp", "test_uploads", Ecto.UUID.generate()])
  end

  defp temp_file_path(name) do
    Path.join(["tmp", "test_uploads", Ecto.UUID.generate(), name])
  end

  defp write_temp_file!(name, contents) do
    path = temp_file_path(name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  test "stores media and returns the public url path" do
    root = uploads_root()
    user = %{id: "42"}

    upload = %Plug.Upload{
      path: fixture_path("DSCN0010.png"),
      filename: "photo.png",
      content_type: "image/png"
    }

    assert {:ok, "/uploads/media/42/" <> filename} = Local.store_media(user, upload, root)

    destination = Path.join([root, "media", "42", filename])
    assert File.exists?(destination)

    thumb_filename = Path.rootname(filename) <> "-thumb.jpg"
    thumb_destination = Path.join([root, "media", "42", thumb_filename])
    assert File.exists?(thumb_destination)
  end

  test "store_media/2 uses the configured upload root" do
    user_id = "configured-root-#{Ecto.UUID.generate()}"

    upload = %Plug.Upload{
      path: fixture_path("DSCN0010.png"),
      filename: "photo.png",
      content_type: "image/png"
    }

    assert {:ok, url_path} = Local.store_media(%{id: user_id}, upload)
    prefix = "/uploads/media/#{user_id}/"
    assert String.starts_with?(url_path, prefix)
    filename = String.replace_prefix(url_path, prefix, "")

    uploads_root = Application.fetch_env!(:egregoros, :uploads_dir)
    destination_dir = Path.join([uploads_root, "media", user_id])
    assert File.exists?(Path.join(destination_dir, filename))
    on_exit(fn -> File.rm_rf!(destination_dir) end)
  end

  test "cleans up safely when the destination directory cannot be created" do
    root_file = write_temp_file!("not-a-directory", "file")
    mp4_path = write_temp_file!("clip.mp4", <<0, 0, 0, 16, "ftyp", "isom", 0, 0, 0, 0>>)

    upload = %Plug.Upload{
      path: mp4_path,
      filename: "clip.mp4",
      content_type: "video/mp4"
    }

    assert {:error, :enotdir} = Local.store_media(%{id: "1"}, upload, root_file)
  end

  test "supports storing video media" do
    root = uploads_root()
    user = %{id: "42"}

    upload_path =
      write_temp_file!(
        "clip.mp4",
        <<0, 0, 0, 24, "ftyp", "isom", 0, 0, 0, 0, "isom", "mp42">>
      )

    upload = %Plug.Upload{
      path: upload_path,
      filename: "clip.mp4",
      content_type: "video/mp4"
    }

    assert {:ok, "/uploads/media/42/" <> filename} = Local.store_media(user, upload, root)

    destination = Path.join([root, "media", "42", filename])
    assert File.exists?(destination)
  end

  test "sniffs supported non-image container and audio signatures" do
    formats = [
      {"clip.mov", "video/quicktime", <<0, 0, 0, 16, "ftyp", "qt  ", 0, 0, 0, 0>>},
      {"clip.webm", "video/webm", <<0x1A, 0x45, 0xDF, 0xA3, 0>>},
      {"sound.wav", "audio/wav", <<"RIFF", 0, 0, 0, 4, "WAVE", 0>>},
      {"sound.ogg", "audio/ogg", <<"OggS", 0, 0, 0, 0>>},
      {"sound.opus", "audio/opus", <<"OggS", 0, 0, 0, 0>>},
      {"sound.mp3", "audio/mpeg", <<"ID3", 4, 0, 0>>},
      {"sound.aac", "audio/aac", <<0xFF, 0xF1, 0>>},
      {"sound.m4a", "audio/mp4", <<0, 0, 0, 16, "ftyp", "M4A ", 0, 0, 0, 0>>}
    ]

    Enum.each(formats, fn {filename, content_type, bytes} ->
      root = uploads_root()
      path = write_temp_file!(filename, bytes)

      upload = %Plug.Upload{path: path, filename: filename, content_type: content_type}

      assert {:ok, "/uploads/media/formats/" <> stored_filename} =
               Local.store_media(%{id: "formats"}, upload, root)

      assert File.exists?(Path.join([root, "media", "formats", stored_filename]))
    end)
  end

  test "sniffs and processes supported JPEG, GIF, and WebP images" do
    Enum.each(
      [
        {"photo.jpg", "image/jpeg"},
        {"photo.gif", "image/gif"},
        {"photo.webp", "image/webp"}
      ],
      fn {filename, content_type} ->
        root = uploads_root()
        path = temp_file_path(filename)
        File.mkdir_p!(Path.dirname(path))
        {:ok, image} = Image.new(8, 8, color: :blue)
        {:ok, _image} = Image.write(image, path)

        upload = %Plug.Upload{path: path, filename: filename, content_type: content_type}

        assert {:ok, "/uploads/media/images/" <> stored_filename} =
                 Local.store_media(%{id: "images"}, upload, root)

        assert File.exists?(Path.join([root, "media", "images", stored_filename]))

        assert File.exists?(
                 Path.join([
                   root,
                   "media",
                   "images",
                   Path.rootname(stored_filename) <> "-thumb.jpg"
                 ])
               )
      end
    )
  end

  test "recognizes HEIF and MPEG frame signatures before failing closed" do
    root = uploads_root()
    heif_path = write_temp_file!("truncated.heic", <<0, 0, 0, 16, "ftyp", "heic", 0, 0, 0, 0>>)

    assert {:error, :invalid_media} =
             Local.store_media(
               %{id: "1"},
               %Plug.Upload{
                 path: heif_path,
                 filename: "truncated.heic",
                 content_type: "image/heic"
               },
               root
             )

    mp3_path = write_temp_file!("frame.mp3", <<0xFF, 0xE3, 0>>)

    assert {:ok, "/uploads/media/1/" <> _filename} =
             Local.store_media(
               %{id: "1"},
               %Plug.Upload{
                 path: mp3_path,
                 filename: "frame.mp3",
                 content_type: "audio/mpeg"
               },
               root
             )
  end

  test "rejects empty files and mismatched supported containers" do
    root = uploads_root()

    empty_path = write_temp_file!("empty.mp3", "")

    assert {:error, :invalid_media} =
             Local.store_media(
               %{id: "1"},
               %Plug.Upload{
                 path: empty_path,
                 filename: "empty.mp3",
                 content_type: "audio/mpeg"
               },
               root
             )

    mp4_path = write_temp_file!("not-webm.webm", <<0, 0, 0, 16, "ftyp", "isom", 0, 0, 0, 0>>)

    assert {:error, :content_type_mismatch} =
             Local.store_media(
               %{id: "1"},
               %Plug.Upload{
                 path: mp4_path,
                 filename: "not-webm.webm",
                 content_type: "video/webm"
               },
               root
             )

    garbage_path = write_temp_file!("garbage.mp4", "not a media container")

    assert {:error, :invalid_media} =
             Local.store_media(
               %{id: "1"},
               %Plug.Upload{
                 path: garbage_path,
                 filename: "garbage.mp4",
                 content_type: "video/mp4"
               },
               root
             )
  end

  test "accepts the GIF87a signature" do
    root = uploads_root()

    gif87 =
      Base.decode16!("47494638376101000100800000000000FFFFFF2C00000000010001000002024401003B")

    path = write_temp_file!("old.gif", gif87)

    assert {:ok, "/uploads/media/gif87/" <> _filename} =
             Local.store_media(
               %{id: "gif87"},
               %Plug.Upload{path: path, filename: "old.gif", content_type: "image/gif"},
               root
             )
  end

  test "rejects unsupported media content types" do
    root = uploads_root()
    user = %{id: "1"}

    upload_path = write_temp_file!("photo.bmp", "nope")

    upload = %Plug.Upload{
      path: upload_path,
      filename: "photo.bmp",
      content_type: "image/bmp"
    }

    assert {:error, :unsupported_media_type} = Local.store_media(user, upload, root)

    assert {:error, :unsupported_media_type} =
             Local.store_media(user, %{upload | content_type: nil}, root)
  end

  test "rejects a declared type that disagrees with the file bytes" do
    root = uploads_root()
    user = %{id: "1"}

    upload = %Plug.Upload{
      path: fixture_path("DSCN0010.png"),
      filename: "photo.jpg",
      content_type: "image/jpeg"
    }

    assert {:error, :content_type_mismatch} = Local.store_media(user, upload, root)
    refute File.exists?(Path.join([root, "media", "1"]))
  end

  test "rejects truncated images and leaves no stored output" do
    root = uploads_root()
    user = %{id: "1"}
    upload_path = write_temp_file!("truncated.png", <<137, 80, 78, 71, 13, 10, 26, 10>>)

    upload = %Plug.Upload{
      path: upload_path,
      filename: "truncated.png",
      content_type: "image/png"
    }

    assert {:error, :invalid_media} = Local.store_media(user, upload, root)
    refute File.exists?(Path.join([root, "media", "1"]))
  end

  test "rejects images whose decoded dimensions exceed the limit" do
    root = uploads_root()
    user = %{id: "1"}
    upload_path = temp_file_path("wide.png")
    File.mkdir_p!(Path.dirname(upload_path))
    {:ok, image} = Image.new(16_385, 1)
    {:ok, _image} = Image.write(image, upload_path)

    upload = %Plug.Upload{
      path: upload_path,
      filename: "wide.png",
      content_type: "image/png"
    }

    assert {:error, :image_dimensions_too_large} =
             Local.store_media(user, upload, root)

    refute File.exists?(Path.join([root, "media", "1"]))
  end

  test "rejects media larger than the size limit" do
    root = uploads_root()
    user = %{id: "1"}

    upload_path = write_temp_file!("big.mp4", :binary.copy("a", 10_000_001))

    upload = %Plug.Upload{
      path: upload_path,
      filename: "big.mp4",
      content_type: "video/mp4"
    }

    assert {:error, :file_too_large} = Local.store_media(user, upload, root)
  end

  test "returns a file error when the upload path is missing" do
    root = uploads_root()
    user = %{id: "1"}

    upload = %Plug.Upload{
      path: Path.join(root, "missing.mp4"),
      filename: "missing.mp4",
      content_type: "video/mp4"
    }

    assert {:error, :enoent} = Local.store_media(user, upload, root)
  end

  defp fixture_path(filename) do
    Path.expand(Path.join(["test", "fixtures", filename]), File.cwd!())
  end
end
