defmodule PleromaRedux.Media do
  import Ecto.Query, only: [from: 2]

  alias PleromaRedux.Object
  alias PleromaRedux.Repo
  alias PleromaRedux.User

  @allowed_types ~w(Document Image)

  def attachments_from_ids(%User{} = user, ids) do
    ids = List.wrap(ids)

    with {:ok, int_ids} <- parse_ids(ids),
         {:ok, objects} <- fetch_owned_media(user, int_ids) do
      attachments =
        int_ids
        |> Enum.map(fn id -> Map.fetch!(objects, id) end)
        |> Enum.map(& &1.data)

      {:ok, attachments}
    end
  end

  def attachments_from_ids(_user, _ids), do: {:ok, []}

  defp parse_ids(ids) when is_list(ids) do
    parsed =
      Enum.map(ids, fn
        id when is_integer(id) -> id
        id when is_binary(id) -> parse_int(id)
        _ -> nil
      end)

    if Enum.any?(parsed, &is_nil/1) do
      {:error, :invalid_media_id}
    else
      {:ok, parsed}
    end
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp fetch_owned_media(_user, []), do: {:ok, %{}}

  defp fetch_owned_media(%User{} = user, ids) when is_list(ids) do
    records =
      from(o in Object,
        where: o.id in ^ids and o.actor == ^user.ap_id and o.type in ^@allowed_types,
        select: o
      )
      |> Repo.all()

    objects = Map.new(records, &{&1.id, &1})

    if map_size(objects) == length(ids) do
      {:ok, objects}
    else
      {:error, :not_found}
    end
  end
end

