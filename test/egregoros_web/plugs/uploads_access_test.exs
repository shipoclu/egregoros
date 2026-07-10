defmodule EgregorosWeb.Plugs.UploadsAccessTest do
  use EgregorosWeb.ConnCase, async: false

  alias Egregoros.MediaVariants
  alias Egregoros.Objects
  alias Egregoros.Users

  test "public media uploads are accessible without auth and cacheable", %{conn: conn} do
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

    {:ok, _media} =
      create_media(author, [url_path, thumbnail_url_path], %{
        "public" => true,
        "post_ap_ids" => []
      })

    on_exit(fn ->
      File.rm_rf!(Path.join([uploads_root, "media", author.id]))
    end)

    conn = get(conn, url_path)
    assert response(conn, 200) == "ok"
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert response(get(conn, thumbnail_url_path), 200) == "thumb"
  end

  test "restricted media requires an authorized local recipient and is revocable", %{conn: conn} do
    {:ok, author} = Users.create_local_user("private-author")
    {:ok, recipient} = Users.create_local_user("private-recipient")
    {:ok, stranger} = Users.create_local_user("private-stranger")

    filename = "private-media.png"
    url_path = "/uploads/media/#{author.id}/#{filename}"
    uploads_root = Application.fetch_env!(:egregoros, :uploads_dir)
    media_dir = Path.join([uploads_root, "media", author.id])
    file_path = Path.join(media_dir, filename)
    File.mkdir_p!(media_dir)
    File.write!(file_path, "secret")

    post_ap_id = "https://example.test/objects/private-post"

    {:ok, post} =
      Objects.create_object(%{
        ap_id: post_ap_id,
        type: "Note",
        actor: author.ap_id,
        local: true,
        data: %{
          "id" => post_ap_id,
          "type" => "Note",
          "actor" => author.ap_id,
          "to" => [recipient.ap_id],
          "cc" => []
        }
      })

    {:ok, _media} =
      create_media(author, [url_path], %{
        "public" => false,
        "post_ap_ids" => [post.ap_id]
      })

    on_exit(fn -> File.rm_rf!(media_dir) end)

    assert response(get(conn, url_path), 404) == "Not Found"

    owner_conn = conn |> recycle() |> init_test_session(%{user_id: author.id}) |> get(url_path)
    assert response(owner_conn, 200) == "secret"
    assert get_resp_header(owner_conn, "cache-control") == ["private, no-store"]

    recipient_conn =
      conn |> recycle() |> init_test_session(%{user_id: recipient.id}) |> get(url_path)

    assert response(recipient_conn, 200) == "secret"

    stranger_conn =
      conn |> recycle() |> init_test_session(%{user_id: stranger.id}) |> get(url_path)

    assert response(stranger_conn, 404) == "Not Found"

    assert {:ok, _tombstone} =
             Objects.update_object(post, %{
               type: "Tombstone",
               data: %{"id" => post.ap_id, "type" => "Tombstone"}
             })

    revoked_conn =
      conn |> recycle() |> init_test_session(%{user_id: recipient.id}) |> get(url_path)

    assert response(revoked_conn, 404) == "Not Found"
  end

  defp create_media(author, paths, access) do
    Objects.create_object(%{
      ap_id: "https://example.test/objects/media-#{Ecto.UUID.generate()}",
      type: "Image",
      actor: author.ap_id,
      local: true,
      data: %{"type" => "Image", "mediaType" => "image/png"},
      internal: %{"media" => Map.merge(%{"paths" => paths}, access)}
    })
  end
end
