defmodule Egregoros.MiniApps.Permissions do
  @moduledoc false

  def subscribe(user_id) when is_binary(user_id) do
    Phoenix.PubSub.subscribe(Egregoros.PubSub, topic(user_id))
  end

  def subscribe(_user_id), do: :ok

  def notify_revoked(user_id, app_origin, kind)
      when is_binary(user_id) and is_binary(app_origin) and
             kind in [:context, :notifications, :oauth, :wallet] do
    Phoenix.PubSub.broadcast(
      Egregoros.PubSub,
      topic(user_id),
      {:mini_app_permission_revoked, app_origin, kind}
    )
  end

  def notify_revoked(_user_id, _app_origin, _kind), do: :ok

  defp topic(user_id), do: "mini-app-permissions:#{user_id}"
end
