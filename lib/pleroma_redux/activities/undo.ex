defmodule PleromaRedux.Activities.Undo do
  alias PleromaRedux.Federation.Delivery
  alias PleromaRedux.Object
  alias PleromaRedux.Objects
  alias PleromaRedux.Users

  def type, do: "Undo"

  def normalize(%{"type" => "Undo"} = activity), do: activity
  def normalize(_), do: nil

  def validate(%{"id" => id, "type" => "Undo", "actor" => actor, "object" => object} = activity)
      when is_binary(id) and is_binary(actor) and is_binary(object) do
    {:ok, activity}
  end

  def validate(_), do: {:error, :invalid}

  def ingest(activity, opts) do
    activity
    |> to_object_attrs(opts)
    |> Objects.upsert_object()
  end

  def side_effects(object, opts) do
    if Keyword.get(opts, :local, true) do
      deliver_undo(object)
    end

    :ok
  end

  defp deliver_undo(%Object{} = undo_object) do
    with %{} = actor <- Users.get_by_ap_id(undo_object.actor),
         %{} = target_activity <- Objects.get_by_ap_id(undo_object.object) do
      do_deliver(actor, target_activity, undo_object)
    end
  end

  defp do_deliver(actor, %Object{type: "Follow"} = follow, undo_object) do
    with %{} = target <- Users.get_by_ap_id(follow.object),
         false <- target.local do
      Delivery.deliver(actor, target.inbox, undo_object.data)
    end
  end

  defp do_deliver(actor, %Object{type: type} = activity, undo_object)
       when type in ["Like", "EmojiReact"] do
    with %{} = target_object <- Objects.get_by_ap_id(activity.object),
         %{} = target <- Users.get_by_ap_id(target_object.actor),
         false <- target.local do
      Delivery.deliver(actor, target.inbox, undo_object.data)
    end
  end

  defp do_deliver(_actor, _activity, _undo_object), do: :ok

  defp to_object_attrs(activity, opts) do
    %{
      ap_id: activity["id"],
      type: activity["type"],
      actor: activity["actor"],
      object: activity["object"],
      data: activity,
      published: parse_datetime(activity["published"]),
      local: Keyword.get(opts, :local, true)
    }
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt
end
