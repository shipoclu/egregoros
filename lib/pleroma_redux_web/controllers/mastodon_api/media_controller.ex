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
    ap_id = Endpoint.url() <> "/objects/" <> Ecto.UUID.generate()
    href = URL.absolute(url_path) || url_path

    Objects.create_object(%{
      ap_id: ap_id,
      type: activity_type(upload.content_type),
      actor: user.ap_id,
      local: true,
      published: DateTime.utc_now(),
      data: %{
        "id" => ap_id,
        "type" => activity_type(upload.content_type),
        "mediaType" => upload.content_type,
        "url" => [
          %{
            "type" => "Link",
            "mediaType" => upload.content_type,
            "href" => href
          }
        ],
        "name" => ""
      }
    })
  end

  defp activity_type(content_type) when is_binary(content_type) do
    if String.starts_with?(content_type, "image/"), do: "Image", else: "Document"
  end

  defp activity_type(_), do: "Document"

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
