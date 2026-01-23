defmodule Egregoros.Workers.PublishScheduledStatus do
  use Oban.Worker, queue: :federation_outgoing, max_attempts: 5

  alias Egregoros.ScheduledStatuses

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scheduled_status_id" => scheduled_status_id}})
      when is_integer(scheduled_status_id) do
    scheduled_status_id
    |> ScheduledStatuses.publish()
    |> case do
      :ok -> :ok
      {:ok, _object} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"scheduled_status_id" => scheduled_status_id}})
      when is_binary(scheduled_status_id) do
    scheduled_status_id
    |> ScheduledStatuses.publish()
    |> case do
      :ok -> :ok
      {:ok, _object} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_args}
end
