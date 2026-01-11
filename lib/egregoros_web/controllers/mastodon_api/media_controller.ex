defmodule EgregorosWeb.MastodonAPI.MediaController do
  use EgregorosWeb, :controller

  alias Egregoros.Media
  alias Egregoros.MediaStorage
  alias Egregoros.Objects
  alias Egregoros.Object
  alias Egregoros.User
  alias EgregorosWeb.URL

  def create(conn, %{"file" => %Plug.Upload{} = upload}) do
    user = conn.assigns.current_user

    with {:ok, url_path} <- MediaStorage.store_media(user, upload),
         {:ok, object} <- Media.create_media_object(user, upload, url_path) do
      json(conn, mastodon_attachment_json(object))
    else
      _ -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def create(conn, _params) do
    send_resp(conn, 422, "Unprocessable Entity")
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with %Object{} = object <- Objects.get(id),
         true <- owned_media?(object, user),
         description when is_binary(description) <- Map.get(params, "description"),
         {:ok, %Object{} = object} <-
           Objects.update_object(object, %{data: update_name(object.data, description)}) do
      json(conn, mastodon_attachment_json(object))
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
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

  defp mastodon_attachment_json(%Object{} = object) do
    href = attachment_url(object)
    url = URL.absolute(href) || href

    meta =
      object.data
      |> Map.get("meta")
      |> case do
        meta when is_map(meta) -> meta
        _ -> %{}
      end

    description =
      object.data
      |> Map.get("name")
      |> case do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end

    %{
      "id" => Integer.to_string(object.id),
      "type" => mastodon_media_type(media_type_from_object(object)),
      "url" => url,
      "preview_url" => url,
      "remote_url" => nil,
      "meta" => meta,
      "description" => description,
      "blurhash" => Map.get(object.data, "blurhash")
    }
  end

  defp media_type_from_object(%Object{data: %{"mediaType" => media_type}})
       when is_binary(media_type),
       do: media_type

  defp media_type_from_object(%Object{data: %{"url" => [%{"mediaType" => media_type} | _]}})
       when is_binary(media_type),
       do: media_type

  defp media_type_from_object(_), do: nil

  defp attachment_url(%Object{data: %{"url" => [%{"href" => href} | _]}}) when is_binary(href),
    do: href

  defp attachment_url(%Object{data: %{"url" => href}}) when is_binary(href), do: href
  defp attachment_url(_), do: ""

  defp owned_media?(%Object{actor: actor, type: type}, %User{ap_id: ap_id})
       when is_binary(actor) and is_binary(ap_id) do
    actor == ap_id and type in ["Image", "Document"]
  end

  defp owned_media?(_object, _user), do: false

  defp update_name(data, description) when is_map(data) and is_binary(description) do
    Map.put(data, "name", description)
  end

  defp update_name(_data, description) when is_binary(description) do
    %{"name" => description}
  end
end
