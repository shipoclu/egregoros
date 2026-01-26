defmodule EgregorosWeb.Plugs.UploadsAccessTest do
  use EgregorosWeb.ConnCase, async: false

  alias Egregoros.MediaVariants
  alias Egregoros.Users

  test "media uploads are accessible without auth (unguessable URLs)", %{conn: conn} do
    {:ok, author} = Users.create_local_user("author")

    filename = "uploads-access-test.png"
    thumbnail_filename = MediaVariants.thumbnail_filename(filename)
    url_path = "/uploads/media/#{author.id}/#{filename}"
    thumbnail_url_path = "/uploads/media/#{author.id}/#{thumbnail_filename}"

    uploads_root = Application.fetch_env!(:egregoros, :uploads_dir)

    media_dir = Path.join([uploads_root, "media", author.id])
    File.mkdir_p!(media_dir)
    file_path = Path.join(media_dir, filename)
    File.write!(file_path, "ok")
    assert File.exists?(file_path)

    thumbnail_file_path = Path.join(media_dir, thumbnail_filename)
    File.write!(thumbnail_file_path, "thumb")
    assert File.exists?(thumbnail_file_path)

    on_exit(fn ->
      File.rm_rf!(Path.join([uploads_root, "media", author.id]))
    end)

    assert response(get(conn, url_path), 200) == "ok"
    assert response(get(conn, thumbnail_url_path), 200) == "thumb"
  end
end
