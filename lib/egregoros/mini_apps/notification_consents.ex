defmodule Egregoros.MiniApps.NotificationConsents do
  @moduledoc false

  import Ecto.Query

  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.NotificationConsent
  alias Egregoros.MiniApps.NotificationAudits
  alias Egregoros.MiniApps.Origin
  alias Egregoros.MiniApps.Permissions
  alias Egregoros.Repo
  alias Egregoros.User

  def state(user_id, app_origin) when is_binary(user_id) and is_binary(app_origin) do
    with {:ok, app_origin} <- Origin.parse_origin(app_origin),
         {:ok, actor_url} <- Declarations.notification_actor(app_origin),
         %NotificationConsent{app_actor_url: ^actor_url, decision: decision} <-
           Repo.get_by(NotificationConsent, user_id: user_id, app_origin: app_origin) do
      decision
    else
      _ -> :prompt
    end
  rescue
    ArgumentError -> :prompt
    Ecto.Query.CastError -> :prompt
  end

  def state(_user_id, _app_origin), do: :prompt

  def granted?(user_id, app_origin), do: state(user_id, app_origin) == :granted

  def decide(user_id, app_origin, decision)
      when is_binary(user_id) and is_binary(app_origin) and decision in [:granted, :denied] do
    with %User{} = user <- Repo.get(User, user_id),
         {:ok, app_origin} <- Origin.parse_origin(app_origin),
         {:ok, actor_url} <- Declarations.notification_actor(app_origin) do
      now = DateTime.utc_now()

      result =
        %NotificationConsent{user_id: user_id}
        |> NotificationConsent.changeset(%{
          app_origin: app_origin,
          app_actor_url: actor_url,
          decision: decision,
          decided_at: now
        })
        |> Repo.insert(
          conflict_target: [:user_id, :app_origin],
          on_conflict: {:replace, [:app_actor_url, :decision, :decided_at, :updated_at]},
          returning: true
        )

      case result do
        {:ok, %NotificationConsent{}} ->
          event = if decision == :granted, do: :permission_granted, else: :permission_denied
          _ = NotificationAudits.record(user, app_origin, actor_url, event)

        _ ->
          :ok
      end

      result
    else
      nil -> {:error, :invalid_user}
      _ -> {:error, :notifications_not_declared}
    end
  rescue
    ArgumentError -> {:error, :invalid_user}
    Ecto.Query.CastError -> {:error, :invalid_user}
  end

  def decide(_user_id, _app_origin, _decision), do: {:error, :invalid_decision}

  def list_for_user(user_id) when is_binary(user_id) do
    from(consent in NotificationConsent,
      where: consent.user_id == ^user_id,
      order_by: [desc: consent.decided_at, asc: consent.app_origin]
    )
    |> Repo.all()
  rescue
    ArgumentError -> []
    Ecto.Query.CastError -> []
  end

  def list_for_user(_user_id), do: []

  def revoke(user_id, app_origin) when is_binary(user_id) and is_binary(app_origin) do
    consent = Repo.get_by(NotificationConsent, user_id: user_id, app_origin: app_origin)

    {count, _rows} =
      from(consent in NotificationConsent,
        where: consent.user_id == ^user_id and consent.app_origin == ^app_origin
      )
      |> Repo.delete_all()

    if count > 0 do
      Permissions.notify_revoked(user_id, app_origin, :notifications)

      with %NotificationConsent{app_actor_url: actor_url} <- consent,
           %User{} = user <- Repo.get(User, user_id) do
        _ = NotificationAudits.record(user, app_origin, actor_url, :permission_revoked)
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
    Ecto.Query.CastError -> :ok
  end

  def revoke(_user_id, _app_origin), do: :ok
end
