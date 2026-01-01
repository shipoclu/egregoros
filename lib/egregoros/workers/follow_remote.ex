defmodule Egregoros.Workers.FollowRemote do
  use Oban.Worker,
    queue: :federation_outgoing,
    max_attempts: 5,
    unique: [period: 60 * 10, keys: [:user_id, :handle]]

  alias Egregoros.Federation
  alias Egregoros.Users

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "handle" => handle}})
      when is_binary(handle) do
    with %Egregoros.User{} = user <- Users.get(user_id),
         {:ok, _remote_user} <- Federation.follow_remote(user, handle) do
      :ok
    else
      nil -> {:discard, :unknown_user}
      {:error, :invalid_handle} -> {:discard, :invalid_handle}
      {:error, :unsafe_url} -> {:discard, :unsafe_url}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :follow_failed}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_args}
end

