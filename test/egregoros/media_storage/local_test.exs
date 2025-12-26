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
    user = %{id: 42}

    upload_path = write_temp_file!("photo.png", "png")

    upload = %Plug.Upload{
      path: upload_path,
      filename: "photo.png",
      content_type: "image/png"
    }

    assert {:ok, "/uploads/media/42/" <> filename} = Local.store_media(user, upload, root)

    destination = Path.join([root, "media", "42", filename])
    assert File.exists?(destination)
  end

  test "supports storing video media" do
    root = uploads_root()
    user = %{id: 42}

    upload_path = write_temp_file!("clip.mp4", "video")

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
    user = %{id: 1}

    upload_path = write_temp_file!("photo.bmp", "nope")

    upload = %Plug.Upload{
      path: upload_path,
      filename: "photo.bmp",
      content_type: "image/bmp"
    }

    assert {:error, :unsupported_media_type} = Local.store_media(user, upload, root)
  end

  test "rejects media larger than the size limit" do
    root = uploads_root()
    user = %{id: 1}

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
    user = %{id: 1}

    upload = %Plug.Upload{
      path: Path.join(root, "missing.mp4"),
      filename: "missing.mp4",
      content_type: "video/mp4"
    }

    assert {:error, :enoent} = Local.store_media(user, upload, root)
  end
end
