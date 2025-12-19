defmodule PleromaReduxWeb.MastodonAPI.MediaController do
  use PleromaReduxWeb, :controller

  alias PleromaRedux.MediaStorage
  alias PleromaRedux.Objects
  alias PleromaReduxWeb.Endpoint
  alias PleromaReduxWeb.URL

  def create(conn, %{"file" => %Plug.Upload{} = upload}) do
    user = conn.assigns.current_user

    with {:ok, url_path} <- MediaStorage.store_media(user, upload),
         {:ok, object} <- create_media_object(user, upload, url_path) do
      url = URL.absolute(url_path) || ""

      json(conn, %{
        "id" => Integer.to_string(object.id),
        "type" => mastodon_media_type(upload.content_type),
        "url" => url,
        "preview_url" => url,
        "remote_url" => nil,
        "meta" => %{},
        "description" => nil,
        "blurhash" => nil
      })
    else
      _ -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def create(conn, _params) do
    send_resp(conn, 422, "Unprocessable Entity")
  end

  defp create_media_object(user, %Plug.Upload{} = upload, url_path) when is_binary(url_path) do
    ap_id = Endpoint.url() <> "/media/" <> Ecto.UUID.generate()

    Objects.create_object(%{
      ap_id: ap_id,
      type: "Media",
      actor: user.ap_id,
      local: true,
      published: DateTime.utc_now(),
      data: %{
        "url" => url_path,
        "preview_url" => url_path,
        "name" => upload.filename,
        "mediaType" => upload.content_type
      }
    })
  end

  defp mastodon_media_type(content_type) when is_binary(content_type) do
    cond do
      String.starts_with?(content_type, "image/") -> "image"
      String.starts_with?(content_type, "video/") -> "video"
      String.starts_with?(content_type, "audio/") -> "audio"
      true -> "unknown"
    end
  end

  defp mastodon_media_type(_), do: "unknown"
end
