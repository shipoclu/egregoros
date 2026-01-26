defmodule EgregorosWeb.MastodonAPI.ScheduledStatusRenderer do
  import Ecto.Query, only: [from: 2]

  alias Egregoros.Object
  alias Egregoros.Repo
  alias Egregoros.ScheduledStatus
  alias Egregoros.User
  alias EgregorosWeb.MastodonAPI.MediaURLs
  alias EgregorosWeb.URL

  @allowed_types ~w(Document Image)

  def render_scheduled_statuses(scheduled_statuses, %User{} = user)
      when is_list(scheduled_statuses) do
    Enum.map(scheduled_statuses, &render_scheduled_status(&1, user))
  end

  def render_scheduled_statuses(_scheduled_statuses, _user), do: []

  def render_scheduled_status(%ScheduledStatus{} = scheduled_status, %User{} = user) do
    params = Map.get(scheduled_status, :params, %{})
    media_ids = Map.get(params, "media_ids", [])

    %{
      "id" => scheduled_status.id,
      "scheduled_at" => format_datetime(scheduled_status.scheduled_at),
      "params" => render_params(params),
      "media_attachments" => render_media_attachments(user, media_ids)
    }
  end

  defp render_params(params) when is_map(params) do
    params =
      params
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Map.new()

    media_ids =
      params
      |> Map.get("media_ids", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    params
    |> Map.put("media_ids", media_ids)
    |> Map.update("sensitive", false, &truthy?/1)
  end

  defp render_params(_params), do: %{}

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp render_media_attachments(%User{} = user, media_ids) do
    media_ids = normalize_media_ids(media_ids)

    if media_ids == [] do
      []
    else
      objects =
        from(o in Object,
          where: o.id in ^media_ids,
          where: o.actor == ^user.ap_id and o.type in ^@allowed_types
        )
        |> Repo.all()

      objects_by_id = Map.new(objects, &{&1.id, &1})

      media_ids
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.flat_map(fn id ->
        case Map.get(objects_by_id, id) do
          %Object{} = object -> [render_attachment(object)]
          _ -> []
        end
      end)
    end
  end

  defp render_media_attachments(_user, _media_ids), do: []

  defp normalize_media_ids(media_ids) do
    media_ids
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.filter(&flake_id?/1)
  end

  defp render_attachment(%Object{} = object) do
    href = attachment_url(object)
    url = URL.absolute(href) || href
    preview_href = MediaURLs.preview_url(object) || href
    preview_url = URL.absolute(preview_href) || preview_href

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
      "id" => media_id(object),
      "type" => mastodon_media_type(media_type_from_object(object)),
      "url" => url,
      "preview_url" => preview_url,
      "remote_url" => nil,
      "meta" => meta,
      "description" => description,
      "blurhash" => Map.get(object.data, "blurhash")
    }
  end

  defp media_id(%Object{id: id}) when is_binary(id) and id != "", do: id
  defp media_id(_object), do: "unknown"

  defp flake_id?(id) when is_binary(id) do
    id = String.trim(id)

    cond do
      id == "" ->
        false

      byte_size(id) < 18 ->
        false

      true ->
        try do
          match?(<<_::128>>, FlakeId.from_string(id))
        rescue
          _ -> false
        end
    end
  end

  defp flake_id?(_id), do: false

  defp mastodon_media_type(content_type) when is_binary(content_type) do
    cond do
      String.starts_with?(content_type, "image/") -> "image"
      String.starts_with?(content_type, "video/") -> "video"
      String.starts_with?(content_type, "audio/") -> "audio"
      true -> "unknown"
    end
  end

  defp mastodon_media_type(_), do: "unknown"

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

  defp format_datetime(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp format_datetime(_dt), do: nil
end
