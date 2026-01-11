defmodule Egregoros.UserEvents do
  @topic_prefix "users:"

  def subscribe(user_ap_id) when is_binary(user_ap_id) do
    user_ap_id = String.trim(user_ap_id)

    if user_ap_id == "" do
      :ok
    else
      Phoenix.PubSub.subscribe(Egregoros.PubSub, topic(user_ap_id))
    end
  end

  def subscribe(_user_ap_id), do: :ok

  def unsubscribe(user_ap_id) when is_binary(user_ap_id) do
    user_ap_id = String.trim(user_ap_id)

    if user_ap_id == "" do
      :ok
    else
      Phoenix.PubSub.unsubscribe(Egregoros.PubSub, topic(user_ap_id))
    end
  end

  def unsubscribe(_user_ap_id), do: :ok

  def broadcast_update(user_ap_id) when is_binary(user_ap_id) do
    user_ap_id = String.trim(user_ap_id)

    if user_ap_id == "" do
      :ok
    else
      Phoenix.PubSub.broadcast(
        Egregoros.PubSub,
        topic(user_ap_id),
        {:user_updated, %{ap_id: user_ap_id}}
      )

      :ok
    end
  end

  def broadcast_update(_user_ap_id), do: :ok

  defp topic(user_ap_id) when is_binary(user_ap_id) do
    @topic_prefix <> user_ap_id
  end
end
