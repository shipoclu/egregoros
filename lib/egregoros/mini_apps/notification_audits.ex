defmodule Egregoros.MiniApps.NotificationAudits do
  @moduledoc false

  import Ecto.Query

  alias Egregoros.Config
  alias Egregoros.MiniApps.NotificationAudit
  alias Egregoros.Repo
  alias Egregoros.User

  @default_retention_limit 500

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
    insert_audit(user_id, %{
      app_origin: origin,
      app_actor_url: actor_url,
      event: event,
      reason: normalize_reason(reason),
      occurred_at: DateTime.utc_now()
    })
  end

  def record(_user, _origin, _actor_url, _event, _reason), do: {:error, :invalid_audit}

  def record_delivery(user, origin, actor_url, activity_id, event, reason \\ nil)

  def record_delivery(
        %User{id: user_id},
        origin,
        actor_url,
        activity_id,
        event,
        reason
      )
      when is_binary(origin) and is_binary(actor_url) and is_binary(activity_id) and
             byte_size(activity_id) > 0 and byte_size(activity_id) <= 2_048 and
             (is_nil(reason) or is_atom(reason) or is_binary(reason)) and
             event in [:delivery_accepted, :delivery_suppressed] do
    insert_audit(user_id, %{
      app_origin: origin,
      app_actor_url: actor_url,
      event: event,
      reason: normalize_reason(reason),
      delivery_fingerprint: delivery_fingerprint(user_id, actor_url, activity_id),
      occurred_at: DateTime.utc_now()
    })
  end

  def record_delivery(_user, _origin, _actor_url, _activity_id, _event, _reason),
    do: {:error, :invalid_audit}

  def delivery_recorded?(%User{id: user_id}, actor_url, activity_id)
      when is_binary(actor_url) and is_binary(activity_id) do
    fingerprint = delivery_fingerprint(user_id, actor_url, activity_id)

    Repo.exists?(
      from(audit in NotificationAudit,
        where: audit.user_id == ^user_id and audit.delivery_fingerprint == ^fingerprint
      )
    )
  end

  def delivery_recorded?(_user, _actor_url, _activity_id), do: false

  def list_for_user(%User{id: user_id}) do
    from(audit in NotificationAudit,
      where: audit.user_id == ^user_id,
      order_by: [desc: audit.occurred_at, desc: audit.id],
      limit: ^retention_limit()
    )
    |> Repo.all()
  end

  def list_for_user(_user), do: []

  defp insert_audit(user_id, attrs) do
    case Repo.transaction(fn ->
           lock_user_audits(user_id)
           insert_and_prune(user_id, attrs)
         end) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :invalid_audit}
    end
  end

  defp insert_and_prune(user_id, attrs) do
    result =
      %NotificationAudit{user_id: user_id}
      |> NotificationAudit.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, _audit} ->
        prune_for_user(user_id)
        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        if Keyword.has_key?(changeset.errors, :delivery_fingerprint),
          do: :duplicate,
          else: {:error, :invalid_audit}
    end
  end

  defp lock_user_audits(user_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtext($1))",
      ["mini-app-notification-audits:" <> user_id]
    )

    :ok
  end

  defp normalize_reason(nil), do: nil
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason) when is_binary(reason), do: reason

  defp delivery_fingerprint(user_id, actor_url, activity_id) do
    secret = EgregorosWeb.Endpoint.config(:secret_key_base)
    input = Enum.join([user_id, actor_url, activity_id], <<0>>)
    :crypto.mac(:hmac, :sha256, secret, input)
  end

  defp prune_for_user(user_id) do
    stale_ids =
      from(audit in NotificationAudit,
        where: audit.user_id == ^user_id,
        order_by: [desc: audit.occurred_at, desc: audit.id],
        offset: ^retention_limit(),
        select: audit.id
      )

    from(audit in NotificationAudit,
      where: audit.user_id == ^user_id and audit.id in subquery(stale_ids)
    )
    |> Repo.delete_all()

    :ok
  end

  defp retention_limit do
    case Config.get(:mini_app_notification_audit_limit, @default_retention_limit) do
      value when is_integer(value) -> value |> max(1) |> min(@default_retention_limit)
      _ -> @default_retention_limit
    end
  end
end
