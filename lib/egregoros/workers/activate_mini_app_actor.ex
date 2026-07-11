defmodule Egregoros.Workers.ActivateMiniAppActor do
  use Oban.Worker,
    queue: :federation_incoming,
    max_attempts: 5,
    unique: [period: 300, keys: [:app_origin]]

  alias Egregoros.MiniApps.ActorActivation
  alias Egregoros.MiniApps.Declaration

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"app_origin" => origin}}) when is_binary(origin) do
    case ActorActivation.activate(origin) do
      {:ok, %Declaration{}} ->
        :ok

      {:error, reason} when reason in [:invalid_actor_document, :actor_not_declared] ->
        {:discard, reason}

      {:error, :declaration_not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_args}

  def maybe_enqueue(%Declaration{
        app_origin: origin,
        activity_pub_actor_url: actor_url,
        activity_pub_actor_public_key_pem: nil
      })
      when is_binary(origin) and is_binary(actor_url) do
    origin
    |> then(&new(%{"app_origin" => &1}))
    |> Oban.insert()
  end

  def maybe_enqueue(%Declaration{}), do: :ok
end
