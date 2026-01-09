defmodule Egregoros.RelationshipEvents do
  @topic_prefix "relationships:user:"

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

  def broadcast_change(type, actor, object)
      when is_binary(type) and is_binary(actor) and is_binary(object) do
    actor = String.trim(actor)
    object = String.trim(object)

    message = {:relationship_changed, %{type: type, actor: actor, object: object}}

    [actor, object]
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.each(fn user_ap_id ->
      Phoenix.PubSub.broadcast(Egregoros.PubSub, topic(user_ap_id), message)
    end)

    :ok
  end

  def broadcast_change(_type, _actor, _object), do: :ok

  defp topic(user_ap_id) when is_binary(user_ap_id) do
    @topic_prefix <> user_ap_id
  end
end
