defmodule Egregoros.MiniApps.NotificationAudits do
  @moduledoc false

  import Ecto.Query

  alias Egregoros.MiniApps.NotificationAudit
  alias Egregoros.Repo
  alias Egregoros.User

  def record(user, origin, actor_url, event, reason \\ nil)

  def record(%User{id: user_id}, origin, actor_url, event, reason)
      when is_binary(origin) and is_binary(actor_url) and
             (is_nil(reason) or is_atom(reason) or is_binary(reason)) and
             event in [
               :permission_granted,
               :permission_denied,
               :permission_revoked,
               :delivery_accepted,
               :delivery_suppressed
             ] do
    attrs = %{
      app_origin: origin,
      app_actor_url: actor_url,
      event: event,
      reason: normalize_reason(reason),
      occurred_at: DateTime.utc_now()
    }

    %NotificationAudit{user_id: user_id}
    |> NotificationAudit.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _audit} -> :ok
      {:error, _changeset} -> {:error, :invalid_audit}
    end
  end

  def record(_user, _origin, _actor_url, _event, _reason), do: {:error, :invalid_audit}

  def list_for_user(%User{id: user_id}) do
    from(audit in NotificationAudit,
      where: audit.user_id == ^user_id,
      order_by: [desc: audit.occurred_at, desc: audit.id]
    )
    |> Repo.all()
  end

  def list_for_user(_user), do: []

  defp normalize_reason(nil), do: nil
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason) when is_binary(reason), do: reason
end
