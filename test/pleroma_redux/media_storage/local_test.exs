defmodule PleromaRedux.MediaStorage.LocalTest do
  use ExUnit.Case, async: true

  alias PleromaRedux.MediaStorage.Local

  defp tmp_upload(content_type, filename) do
    path = Path.join(System.tmp_dir!(), "pleroma-redux-test-upload-#{Ecto.UUID.generate()}")
    File.write!(path, <<0, 1, 2, 3>>)

    %Plug.Upload{
      path: path,
      filename: filename,
      content_type: content_type
    }
  end

  test "stores video attachments" do
    uploads_root =
      Path.join(System.tmp_dir!(), "pleroma-redux-test-uploads-#{Ecto.UUID.generate()}")

    upload = tmp_upload("video/mp4", "clip.mp4")

    assert {:ok, url_path} = Local.store_media(%{id: 123}, upload, uploads_root)
    assert url_path =~ ~r|^/uploads/media/123/.+\.mp4$|

    stored_path = Path.join([uploads_root, "media", "123", Path.basename(url_path)])
    assert File.exists?(stored_path)
  end

  test "stores HEIC images" do
    uploads_root =
      Path.join(System.tmp_dir!(), "pleroma-redux-test-uploads-#{Ecto.UUID.generate()}")

    upload = tmp_upload("image/heic", "photo.heic")

    assert {:ok, url_path} = Local.store_media(%{id: 123}, upload, uploads_root)
    assert url_path =~ ~r|^/uploads/media/123/.+\.heic$|

    stored_path = Path.join([uploads_root, "media", "123", Path.basename(url_path)])
    assert File.exists?(stored_path)
  end
end
