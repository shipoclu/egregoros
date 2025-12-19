defmodule PleromaRedux.Activities.Delete do
  alias PleromaRedux.Federation.Delivery
  alias PleromaRedux.Object
  alias PleromaRedux.Objects
  alias PleromaRedux.Relationships
  alias PleromaRedux.User
  alias PleromaRedux.Users
  alias PleromaReduxWeb.Endpoint

  @public "https://www.w3.org/ns/activitystreams#Public"

  def type, do: "Delete"

  def build(%User{ap_id: actor}, %Object{} = object) do
    build(actor, object)
  end

  def build(actor, %Object{ap_id: object_id} = object)
      when is_binary(actor) and is_binary(object_id) do
    base = build(actor, object_id)

    case object.data do
      %{} = data when map_size(data) > 0 -> maybe_copy_addressing(base, data)
      _ -> base
    end
  end

  def build(%User{ap_id: actor}, object_id) when is_binary(object_id) do
    build(actor, object_id)
  end

  def build(actor, object_id) when is_binary(actor) and is_binary(object_id) do
    %{
      "id" => Endpoint.url() <> "/activities/delete/" <> Ecto.UUID.generate(),
      "type" => type(),
      "actor" => actor,
      "object" => object_id,
      "to" => [@public],
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  def normalize(%{"type" => "Delete"} = activity), do: activity
  def normalize(_), do: nil

  def validate(%{"id" => id, "type" => "Delete", "actor" => actor, "object" => object} = activity)
      when is_binary(id) and is_binary(actor) do
    case object do
      object_id when is_binary(object_id) and object_id != "" ->
        {:ok, activity}

      %{"id" => object_id} when is_binary(object_id) and object_id != "" ->
        {:ok, Map.put(activity, "object", object_id)}

      _ ->
        {:error, :invalid}
    end
  end

  def validate(_), do: {:error, :invalid}

  def ingest(activity, opts) do
    activity
    |> to_object_attrs(opts)
    |> Objects.upsert_object()
  end

  def side_effects(%Object{} = delete_object, opts) do
    target = Objects.get_by_ap_id(delete_object.object)
    _ = delete_target(delete_object, target)

    if Keyword.get(opts, :local, true) do
      deliver_delete(delete_object)
    end

    :ok
  end

  defp delete_target(%Object{actor: actor} = _delete_object, %Object{actor: actor} = target) do
    _ = Objects.delete_object(target)
    _ = Relationships.delete_all_for_object(target.ap_id)
    :ok
  end

  defp delete_target(_delete_object, _target), do: :ok

  defp deliver_delete(%Object{} = delete_object) do
    with %{} = actor <- Users.get_by_ap_id(delete_object.actor) do
      actor.ap_id
      |> Relationships.list_follows_to()
      |> Enum.each(fn follow ->
        with %{} = follower <- Users.get_by_ap_id(follow.actor),
             false <- follower.local do
          Delivery.deliver(actor, follower.inbox, delete_object.data)
        end
      end)
    end
  end

  defp maybe_copy_addressing(activity, %{"to" => to} = target_data) when is_list(to) do
    activity
    |> Map.put("to", to)
    |> maybe_copy_cc(target_data)
  end

  defp maybe_copy_addressing(activity, target_data), do: maybe_copy_cc(activity, target_data)

  defp maybe_copy_cc(activity, %{"cc" => cc}) when is_list(cc), do: Map.put(activity, "cc", cc)
  defp maybe_copy_cc(activity, _), do: activity

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
