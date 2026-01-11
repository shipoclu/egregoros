defmodule Egregoros.Workers.RefreshRemoteUserCounts do
  use Oban.Worker,
    queue: :federation_incoming,
    max_attempts: 3,
    unique: [period: 60 * 60, keys: [:ap_id]]

  alias Egregoros.Federation.Actor
  alias Egregoros.User
  alias Egregoros.UserEvents

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ap_id" => ap_id}}) when is_binary(ap_id) do
    case Actor.fetch_and_store_with_counts(ap_id) do
      {:ok, %User{ap_id: ap_id}} ->
        _ = UserEvents.broadcast_update(ap_id)
        :ok

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :actor_refresh_failed}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_args}
end
