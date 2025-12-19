defmodule PleromaRedux.Activities.EmojiReact do
  alias PleromaRedux.Federation.Delivery
  alias PleromaRedux.Object
  alias PleromaRedux.Objects
  alias PleromaRedux.User
  alias PleromaRedux.Users
  alias PleromaReduxWeb.Endpoint

  @public "https://www.w3.org/ns/activitystreams#Public"

  def type, do: "EmojiReact"

  def build(%User{ap_id: actor}, %Object{} = object, content) when is_binary(content) do
    build(actor, object, content)
  end

  def build(actor, %Object{ap_id: object_id} = object, content)
      when is_binary(actor) and is_binary(object_id) and is_binary(content) do
    build(actor, object_id, content, object)
  end

  def build(%User{ap_id: actor}, object_id, content)
      when is_binary(object_id) and is_binary(content) do
    build(actor, object_id, content)
  end

  def build(actor, object_id, content)
      when is_binary(actor) and is_binary(object_id) and is_binary(content) do
    %{
      "id" => Endpoint.url() <> "/activities/react/" <> Ecto.UUID.generate(),
      "type" => type(),
      "actor" => actor,
      "object" => object_id,
      "content" => String.trim(content),
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp build(actor, object_id, content, %Object{} = object) do
    base = build(actor, object_id, content)

    case recipients(actor, object) do
      %{} = recipients when map_size(recipients) > 0 -> Map.merge(base, recipients)
      _ -> base
    end
  end

  def normalize(%{"type" => "EmojiReact"} = activity) do
    trim_content(activity)
  end

  def normalize(_), do: nil

  def validate(
        %{
          "id" => id,
          "type" => "EmojiReact",
          "actor" => actor,
          "object" => object,
          "content" => content
        } = activity
      )
      when is_binary(id) and is_binary(actor) and is_binary(object) and is_binary(content) and
             content != "" do
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
      deliver_reaction(object)
    end

    :ok
  end

  defp deliver_reaction(object) do
    with %{} = actor <- Users.get_by_ap_id(object.actor),
         %{} = reacted_object <- Objects.get_by_ap_id(object.object),
         %{} = target <- get_or_fetch_user(reacted_object.actor),
         false <- target.local do
      Delivery.deliver(actor, target.inbox, object.data)
    end
  end

  defp get_or_fetch_user(nil), do: nil

  defp get_or_fetch_user(ap_id) when is_binary(ap_id) do
    Users.get_by_ap_id(ap_id) ||
      case PleromaRedux.Federation.Actor.fetch_and_store(ap_id) do
        {:ok, user} -> user
        _ -> nil
      end
  end

  defp recipients(actor, %Object{actor: object_actor} = object) when is_binary(object_actor) do
    to =
      if public_object?(object) do
        [actor <> "/followers", object_actor]
      else
        [object_actor]
      end

    %{"to" => Enum.uniq(to)}
  end

  defp recipients(_actor, _object), do: %{}

  defp public_object?(%Object{data: %{"to" => to}}) when is_list(to), do: @public in to
  defp public_object?(_), do: false

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

  defp trim_content(%{"content" => content} = activity) when is_binary(content) do
    Map.put(activity, "content", String.trim(content))
  end

  defp trim_content(activity), do: activity

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt
end
