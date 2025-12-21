defmodule PleromaRedux.AvatarStorage.LocalTest do
  use ExUnit.Case, async: true

  alias PleromaRedux.AvatarStorage.Local

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

  test "stores an avatar and returns the public url path" do
    root = uploads_root()
    user = %{id: 123}

    upload_path = write_temp_file!("avatar.png", "png")

    upload = %Plug.Upload{
      path: upload_path,
      filename: "avatar.png",
      content_type: "image/png"
    }

    assert {:ok, "/uploads/avatars/123/" <> filename} = Local.store_avatar(user, upload, root)

    destination = Path.join([root, "avatars", "123", filename])
    assert File.exists?(destination)
  end

  test "rejects unsupported avatar content types" do
    root = uploads_root()
    user = %{id: 1}

    upload_path = write_temp_file!("avatar.txt", "nope")

    upload = %Plug.Upload{
      path: upload_path,
      filename: "avatar.txt",
      content_type: "text/plain"
    }

    assert {:error, :unsupported_media_type} = Local.store_avatar(user, upload, root)
  end

  test "rejects avatars larger than the size limit" do
    root = uploads_root()
    user = %{id: 1}

    upload_path = write_temp_file!("big.png", :binary.copy("a", 5_000_001))

    upload = %Plug.Upload{
      path: upload_path,
      filename: "big.png",
      content_type: "image/png"
    }

    assert {:error, :file_too_large} = Local.store_avatar(user, upload, root)
  end

  test "returns a file error when the upload path is missing" do
    root = uploads_root()
    user = %{id: 1}

    upload = %Plug.Upload{
      path: Path.join(root, "missing.png"),
      filename: "missing.png",
      content_type: "image/png"
    }

    assert {:error, :enoent} = Local.store_avatar(user, upload, root)
  end
end

