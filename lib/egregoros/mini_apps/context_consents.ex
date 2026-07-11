defmodule Egregoros.MiniApps.ContextConsents do
  @moduledoc false

  import Ecto.Query

  alias Egregoros.MiniApps
  alias Egregoros.MiniApps.ContextConsent
  alias Egregoros.MiniApps.Origin
  alias Egregoros.MiniApps.Permissions
  alias Egregoros.Repo

  def approved?(user_id, app_origin) when is_binary(user_id) and is_binary(app_origin) do
    with {:ok, app_origin} <- Origin.parse_origin(app_origin),
         true <- origin_allowed?(app_origin) do
      Repo.exists?(
        from(consent in ContextConsent,
          where: consent.user_id == ^user_id and consent.app_origin == ^app_origin
        )
      )
    else
      _ -> false
    end
  rescue
    ArgumentError -> false
    Ecto.Query.CastError -> false
  end

  def approved?(_user_id, _app_origin), do: false

  def grant(user_id, app_origin) when is_binary(user_id) and is_binary(app_origin) do
    now = DateTime.utc_now()

    %ContextConsent{}
    |> ContextConsent.changeset(%{
      user_id: user_id,
      app_origin: app_origin,
      approved_at: now
    })
    |> Repo.insert(
      conflict_target: [:user_id, :app_origin],
      on_conflict: {:replace, [:approved_at, :updated_at]},
      returning: true
    )
  end

  def list_for_user(user_id) when is_binary(user_id) do
    from(consent in ContextConsent,
      where: consent.user_id == ^user_id,
      order_by: [desc: consent.approved_at, asc: consent.app_origin]
    )
    |> Repo.all()
  rescue
    ArgumentError -> []
    Ecto.Query.CastError -> []
  end

  def list_for_user(_user_id), do: []

  def revoke(user_id, app_origin) when is_binary(user_id) and is_binary(app_origin) do
    {count, _rows} =
      from(consent in ContextConsent,
        where: consent.user_id == ^user_id and consent.app_origin == ^app_origin
      )
      |> Repo.delete_all()

    if count > 0, do: Permissions.notify_revoked(user_id, app_origin, :context)

    :ok
  rescue
    ArgumentError -> :ok
    Ecto.Query.CastError -> :ok
  end

  defp origin_allowed?(origin) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) -> MiniApps.domain_allowed?(host)
      _ -> false
    end
  end
end
