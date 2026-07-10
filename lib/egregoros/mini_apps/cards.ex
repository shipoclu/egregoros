defmodule Egregoros.MiniApps.Cards do
  @moduledoc false

  import Ecto.Query

  alias Egregoros.MiniApps.Card
  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.ResolvedCard
  alias Egregoros.MiniApps
  alias Egregoros.Object
  alias Egregoros.Repo

  @replace_fields ~w(
    source_url app_origin app_name title button_title launch_url image_url resolved_at expires_at
    updated_at
  )a

  def put(%Object{id: object_id}, %ResolvedCard{} = resolved) when not is_nil(object_id) do
    resolved_at = DateTime.utc_now()
    expires_at = DateTime.add(resolved_at, resolved.manifest.cache_ttl_seconds, :second)

    attrs = %{
      object_id: object_id,
      source_url: resolved.source_url,
      app_origin: resolved.app_origin,
      app_name: resolved.app_name,
      title: resolved.title,
      button_title: resolved.button_title,
      launch_url: resolved.launch_url,
      image_url: resolved.image_url,
      resolved_at: resolved_at,
      expires_at: expires_at
    }

    changeset = Card.changeset(%Card{}, attrs)

    if changeset.valid? do
      with {:ok, _declaration, _status} <- Declarations.ensure(resolved.manifest) do
        Repo.insert(changeset,
          conflict_target: :object_id,
          on_conflict: {:replace, @replace_fields},
          returning: true
        )
      end
    else
      {:error, changeset}
    end
  end

  def put(%Object{}, %ResolvedCard{}) do
    %Card{}
    |> Card.changeset(%{})
    |> Ecto.Changeset.add_error(:object_id, "must identify a persisted object")
    |> then(&{:error, &1})
  end

  def get_active(%Object{id: object_id}) when not is_nil(object_id) do
    [object_id]
    |> list_active_for_object_ids()
    |> Map.get(object_id)
  end

  def get_active(%Object{}), do: nil

  def get_active_by_id(card_id) when is_binary(card_id) do
    if MiniApps.enabled?() do
      now = DateTime.utc_now()

      Card
      |> Repo.get(card_id)
      |> case do
        %Card{expires_at: expires_at} = card ->
          if DateTime.after?(expires_at, now) and card_allowed?(card), do: card

        _ ->
          nil
      end
    end
  rescue
    ArgumentError -> nil
    Ecto.Query.CastError -> nil
  end

  def get_active_by_id(_card_id), do: nil

  def list_active_for_objects(objects) when is_list(objects) do
    objects
    |> Enum.map(fn
      %Object{id: id} when not is_nil(id) -> id
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> list_active_for_object_ids()
  end

  def delete(%Object{id: object_id}) when not is_nil(object_id) do
    from(card in Card, where: card.object_id == ^object_id)
    |> Repo.delete_all()

    :ok
  end

  def delete(%Object{}), do: :ok

  defp list_active_for_object_ids([]), do: %{}

  defp list_active_for_object_ids(object_ids) do
    if MiniApps.enabled?() do
      now = DateTime.utc_now()

      from(card in Card,
        where: card.object_id in ^object_ids and card.expires_at > ^now
      )
      |> Repo.all()
      |> Enum.filter(&card_allowed?/1)
      |> Map.new(&{&1.object_id, &1})
    else
      %{}
    end
  end

  defp card_allowed?(%Card{app_origin: origin}) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) -> MiniApps.domain_allowed?(host)
      _ -> false
    end
  end

  defp card_allowed?(_card), do: false
end
