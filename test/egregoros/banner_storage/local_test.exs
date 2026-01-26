defmodule Egregoros.BannerStorage.LocalTest do
  use ExUnit.Case, async: true

  alias Egregoros.BannerStorage.Local

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

  test "stores a banner and returns the public url path" do
    root = uploads_root()
    user = %{id: "123"}

    upload_path = write_temp_file!("banner.png", "png")

    upload = %Plug.Upload{
      path: upload_path,
      filename: "banner.png",
      content_type: "image/png"
    }

    assert {:ok, "/uploads/banners/123/" <> filename} = Local.store_banner(user, upload, root)

    destination = Path.join([root, "banners", "123", filename])
    assert File.exists?(destination)
  end

  test "rejects unsupported banner content types" do
    root = uploads_root()
    user = %{id: "1"}

    upload_path = write_temp_file!("banner.txt", "nope")

    upload = %Plug.Upload{
      path: upload_path,
      filename: "banner.txt",
      content_type: "text/plain"
    }

    assert {:error, :unsupported_media_type} = Local.store_banner(user, upload, root)
  end

  test "rejects banners larger than the size limit" do
    root = uploads_root()
    user = %{id: "1"}

    upload_path = write_temp_file!("big.png", :binary.copy("a", 10_000_001))

    upload = %Plug.Upload{
      path: upload_path,
      filename: "big.png",
      content_type: "image/png"
    }

    assert {:error, :file_too_large} = Local.store_banner(user, upload, root)
  end

  test "returns a file error when the upload path is missing" do
    root = uploads_root()
    user = %{id: "1"}

    upload = %Plug.Upload{
      path: Path.join(root, "missing.png"),
      filename: "missing.png",
      content_type: "image/png"
    }

    assert {:error, :enoent} = Local.store_banner(user, upload, root)
  end
end
