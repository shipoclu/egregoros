defmodule Egregoros.Workers.DeliverToActor do
  use Oban.Worker,
    queue: :federation_outgoing,
    max_attempts: 5,
    unique: [period: 60 * 10, keys: [:activity_id, :target_actor_ap_id]]

  alias Egregoros.Federation.Actor
  alias Egregoros.Federation.Delivery
  alias Egregoros.User
  alias Egregoros.Users

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "user_id" => user_id,
          "target_actor_ap_id" => target_actor_ap_id,
          "activity" => activity
        }
      })
      when is_binary(target_actor_ap_id) and is_map(activity) do
    with %User{} = actor <- Users.get(user_id),
         {:ok, %User{} = target} <- get_or_fetch_target(target_actor_ap_id),
         false <- target.local,
         inbox when is_binary(inbox) and inbox != "" <- target.inbox,
         {:ok, _job} <- Delivery.deliver(actor, inbox, activity) do
      :ok
    else
      nil -> {:discard, :unknown_user}
      true -> :ok
      {:error, :unsafe_url} -> {:discard, :unsafe_url}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :delivery_failed}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_args}

  defp get_or_fetch_target(target_actor_ap_id) when is_binary(target_actor_ap_id) do
    target_actor_ap_id = String.trim(target_actor_ap_id)

    case Users.get_by_ap_id(target_actor_ap_id) do
      %User{} = user ->
        {:ok, user}

      nil ->
        Actor.fetch_and_store(target_actor_ap_id)
    end
  end

  defp get_or_fetch_target(_target_actor_ap_id), do: {:error, :invalid_target}
end
