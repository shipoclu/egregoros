defmodule Egregoros.Media do
  import Ecto.Query, only: [from: 2]

  alias Egregoros.MediaMeta
  alias Egregoros.MediaVariants
  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Relationships
  alias Egregoros.Repo
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint
  alias EgregorosWeb.URL

  @allowed_types ~w(Document Image)

  def create_media_object(%User{} = user, %Plug.Upload{} = upload, url_path, opts \\ [])
      when is_binary(url_path) and is_list(opts) do
    ap_id = Endpoint.url() <> "/objects/" <> Ecto.UUID.generate()
    href = URL.absolute(url_path) || url_path
    {meta, blurhash} = MediaMeta.info(upload)
    icon = icon(upload, url_path)

    description =
      opts
      |> Keyword.get(:description, "")
      |> to_string()
      |> String.trim()

    Objects.create_object(%{
      ap_id: ap_id,
      type: activity_type(upload.content_type),
      actor: user.ap_id,
      local: true,
      published: DateTime.utc_now(),
      internal: %{
        "media" => %{
          "paths" => media_paths(url_path, upload),
          "public" => false,
          "post_ap_ids" => []
        }
      },
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
        "meta" => meta,
        "blurhash" => blurhash,
        "icon" => icon,
        "name" => description
      }
    })
  end

  def bind_attachments(%Object{actor: actor, data: %{} = data} = post)
      when is_binary(actor) do
    attachment_ids =
      data
      |> Map.get("attachment", [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"id" => id} when is_binary(id) -> [id]
        _ -> []
      end)

    public? = Objects.publicly_visible?(post)

    attachment_ids
    |> Objects.list_by_ap_ids()
    |> Enum.filter(&(&1.actor == actor and &1.local))
    |> Enum.reduce_while(:ok, fn media, :ok ->
      media_state = get_in(media.internal || %{}, ["media"]) || %{}
      post_ap_ids = [post.ap_id | List.wrap(media_state["post_ap_ids"])] |> Enum.uniq()

      updated_state =
        media_state
        |> Map.put("post_ap_ids", post_ap_ids)
        |> Map.put("public", media_state["public"] == true or public?)

      internal = Map.put(media.internal || %{}, "media", updated_state)

      case Objects.update_object(media, %{internal: internal}) do
        {:ok, _media} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def bind_attachments(_post), do: :ok

  def access_for_path(path, requester_actor_ap_id \\ nil)

  def access_for_path(path, requester_actor_ap_id) when is_binary(path) do
    case media_by_path(path) do
      %Object{} = media ->
        media_state = get_in(media.internal || %{}, ["media"]) || %{}

        cond do
          media_state["public"] == true -> :public
          requester_actor_ap_id == media.actor -> :restricted
          authorized_for_linked_post?(media_state, requester_actor_ap_id) -> :restricted
          true -> :denied
        end

      nil ->
        :denied
    end
  end

  def access_for_path(_path, _requester_actor_ap_id), do: :denied

  def attachments_from_ids(%User{} = user, ids) do
    ids = List.wrap(ids)

    with {:ok, parsed_ids} <- parse_ids(ids),
         {:ok, objects} <- fetch_owned_media(user, parsed_ids) do
      attachments =
        render_attachments(parsed_ids, objects)

      {:ok, attachments}
    end
  end

  def attachments_from_ids(_user, _ids), do: {:ok, []}

  defp parse_ids(ids) when is_list(ids) do
    parsed =
      ids
      |> Enum.flat_map(fn
        id when is_binary(id) ->
          id = String.trim(id)

          if flake_id?(id) do
            [id]
          else
            []
          end

        _ ->
          []
      end)

    cond do
      length(parsed) != length(ids) ->
        {:error, :invalid_media_id}

      true ->
        {:ok, parsed}
    end
  end

  defp fetch_owned_media(_user, []), do: {:ok, []}

  defp fetch_owned_media(%User{} = user, ids) when is_list(ids) do
    records =
      from(o in Object,
        where: o.id in ^ids and o.actor == ^user.ap_id and o.type in ^@allowed_types,
        select: o
      )
      |> Repo.all()

    found_ids = MapSet.new(Enum.map(records, & &1.id))
    expected_ids = MapSet.new(ids)

    if MapSet.subset?(expected_ids, found_ids) do
      {:ok, records}
    else
      {:error, :not_found}
    end
  end

  defp render_attachments(ids, objects) when is_list(ids) and is_list(objects) do
    objects_by_id = Map.new(objects, &{&1.id, &1})

    Enum.flat_map(ids, fn id ->
      case Map.get(objects_by_id, id) do
        %Object{} = object -> [object.data]
        _ -> []
      end
    end)
  end

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

  defp activity_type(content_type) when is_binary(content_type) do
    if String.starts_with?(content_type, "image/"), do: "Image", else: "Document"
  end

  defp activity_type(_), do: "Document"

  defp media_paths(url_path, upload) do
    paths = [url_path]

    if is_binary(upload.content_type) and String.starts_with?(upload.content_type, "image/") do
      [MediaVariants.thumbnail_url_path(url_path) | paths]
    else
      paths
    end
  end

  defp media_by_path("/uploads/media/" <> rest = path) do
    with [user_id, _filename] <- String.split(rest, "/", parts: 2),
         %User{} = owner <- Users.get(user_id) do
      from(o in Object,
        where: o.actor == ^owner.ap_id and o.type in ^@allowed_types,
        order_by: [desc: o.inserted_at]
      )
      |> Repo.all()
      |> Enum.find(fn object ->
        path in List.wrap(get_in(object.internal || %{}, ["media", "paths"]))
      end)
    else
      _ -> nil
    end
  end

  defp media_by_path(_path), do: nil

  defp authorized_for_linked_post?(_media_state, requester)
       when not is_binary(requester) or requester == "",
       do: false

  defp authorized_for_linked_post?(media_state, requester) do
    media_state
    |> Map.get("post_ap_ids", [])
    |> List.wrap()
    |> Enum.any?(fn post_ap_id ->
      case Objects.get_by_ap_id(post_ap_id) do
        %Object{type: type} = post when type != "Tombstone" ->
          post_accessible_to?(post, requester)

        _ ->
          false
      end
    end)
  end

  defp post_accessible_to?(%Object{actor: requester}, requester), do: true

  defp post_accessible_to?(%Object{actor: actor, data: data}, requester)
       when is_binary(actor) and is_map(data) do
    recipients = Egregoros.Recipients.recipient_actor_ids(data, fields: ["to", "cc"])

    requester in recipients or
      ((actor <> "/followers") in recipients and
         not is_nil(Relationships.get_by_type_actor_object("Follow", requester, actor)))
  end

  defp post_accessible_to?(_post, _requester), do: false

  defp icon(%Plug.Upload{content_type: "image/" <> _}, url_path) when is_binary(url_path) do
    preview_url_path = MediaVariants.thumbnail_url_path(url_path)
    preview_href = URL.absolute(preview_url_path) || preview_url_path
    media_type = MediaVariants.thumbnail_content_type()

    %{
      "type" => "Image",
      "mediaType" => media_type,
      # Mastodon expects `icon.url` to be a string, not an array of links.
      # Use a simple URL for compatibility.
      "url" => preview_href
    }
  end

  defp icon(_upload, _url_path), do: nil
end
