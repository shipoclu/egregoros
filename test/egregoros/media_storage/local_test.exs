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
