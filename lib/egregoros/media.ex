defmodule Egregoros.Media do
  import Ecto.Query, only: [from: 2]

  alias Egregoros.Object
  alias Egregoros.Repo
  alias Egregoros.User
  alias Egregoros.Objects
  alias Egregoros.MediaMeta
  alias Egregoros.MediaVariants
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
