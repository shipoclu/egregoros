defmodule Egregoros.Relays do
  import Ecto.Query, only: [from: 2]

  alias Egregoros.Activities.Follow
  alias Egregoros.Federation.Actor
  alias Egregoros.Federation.InternalFetchActor
  alias Egregoros.Pipeline
  alias Egregoros.Relay
  alias Egregoros.Relationships
  alias Egregoros.Repo
  alias Egregoros.SafeURL

  def list_relays do
    from(r in Relay, order_by: [asc: r.ap_id])
    |> Repo.all()
  end

  def subscribed?(ap_id) when is_binary(ap_id) do
    ap_id = String.trim(ap_id)

    if ap_id == "" do
      false
    else
      Repo.exists?(from(r in Relay, where: r.ap_id == ^ap_id))
    end
  end

  def subscribed?(_ap_id), do: false

  def subscribe(relay_ap_id) when is_binary(relay_ap_id) do
    relay_ap_id = String.trim(relay_ap_id)

    with :ok <- SafeURL.validate_http_url(relay_ap_id),
         {:ok, relay_user} <- Actor.fetch_and_store(relay_ap_id),
         {:ok, internal} <- InternalFetchActor.get_actor(),
         {:ok, relay} <- upsert_relay(relay_user.ap_id),
         :ok <- ensure_following(internal.ap_id, relay_user.ap_id, internal, relay_user) do
      {:ok, relay}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_relay}
    end
  end

  def subscribe(_relay_ap_id), do: {:error, :invalid_relay}

  defp upsert_relay(ap_id) when is_binary(ap_id) do
    case Repo.get_by(Relay, ap_id: ap_id) do
      %Relay{} = relay ->
        {:ok, relay}

      nil ->
        %Relay{}
        |> Relay.changeset(%{ap_id: ap_id})
        |> Repo.insert()
    end
  end

  defp ensure_following(internal_ap_id, relay_ap_id, internal, relay_user)
       when is_binary(internal_ap_id) and is_binary(relay_ap_id) do
    cond do
      Relationships.get_by_type_actor_object("Follow", internal_ap_id, relay_ap_id) != nil ->
        :ok

      true ->
        case Pipeline.ingest(Follow.build(internal, relay_user), local: true) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
          _ -> {:error, :follow_failed}
        end
    end
  end
end
