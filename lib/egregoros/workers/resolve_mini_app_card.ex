defmodule Egregoros.Workers.ResolveMiniAppCard do
  use Oban.Worker,
    queue: :federation_incoming,
    max_attempts: 3,
    unique: [period: 60, keys: [:object_id]]

  alias Egregoros.MiniApps
  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.Discovery
  alias Egregoros.Object
  alias Egregoros.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"object_id" => object_id}}) when is_binary(object_id) do
    case get_object(object_id) do
      nil ->
        :ok

      %Object{} = object ->
        resolve(object)
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_args}

  def maybe_enqueue(%Object{id: object_id} = object) when not is_nil(object_id) do
    if MiniApps.enabled?() and Discovery.candidate_urls(object) != [] do
      object_id
      |> then(&new(%{"object_id" => &1}))
      |> Oban.insert()
    end

    :ok
  end

  def maybe_enqueue(%Object{}), do: :ok

  defp resolve(object) do
    candidates = Discovery.candidate_urls(object)

    cond do
      not MiniApps.enabled?() ->
        Cards.delete(object)

      candidates == [] ->
        Cards.delete(object)

      true ->
        case MiniApps.resolve_note(object) do
          {:ok, resolved} ->
            case Cards.put(object, resolved) do
              {:ok, _card} -> :ok
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp get_object(object_id) do
    Repo.get(Object, object_id)
  rescue
    Ecto.Query.CastError -> nil
    ArgumentError -> nil
  end
end
