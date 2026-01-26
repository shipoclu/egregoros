defmodule EgregorosWeb.MastodonAPI.NotificationRenderer do
  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Relationships
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.MastodonAPI.AccountRenderer
  alias EgregorosWeb.MastodonAPI.Fallback
  alias EgregorosWeb.MastodonAPI.StatusRenderer

  @status_object_types ~w(Like Announce EmojiReact)

  def render_notifications(activities, current_user) when is_list(activities) do
    ctx = rendering_context(activities, current_user)
    Enum.map(activities, &render_notification_with_context(&1, ctx))
  end

  def render_notifications(_activities, _current_user), do: []

  def render_notification(%Object{} = activity, %User{} = current_user) do
    notifications_last_seen_id = Map.get(current_user, :notifications_last_seen_id)

    status =
      case activity.type do
        "Like" -> Objects.get_by_ap_id(activity.object)
        "Announce" -> Objects.get_by_ap_id(activity.object)
        "Note" -> activity
        _ -> nil
      end

    %{
      "id" => notification_id(activity),
      "type" => mastodon_type(activity.type),
      "created_at" => format_datetime(activity),
      "account" => AccountRenderer.render_account(account_for_actor(activity.actor)),
      "status" => if(status, do: StatusRenderer.render_status(status, current_user), else: nil),
      "pleroma" => %{
        "is_seen" => seen?(activity, notifications_last_seen_id)
      }
    }
  end

  def render_notification(%Object{} = activity, current_user) do
    [rendered] = render_notifications([activity], current_user)
    rendered
  end

  def render_notification(_activity, _current_user) do
    %{
      "id" => "unknown",
      "type" => "unknown",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "account" => AccountRenderer.render_account(%{ap_id: "unknown", nickname: "unknown"}),
      "status" => nil,
      "pleroma" => %{"is_seen" => false}
    }
  end

  defp mastodon_type("Follow"), do: "follow"
  defp mastodon_type("Like"), do: "favourite"
  defp mastodon_type("Announce"), do: "reblog"
  defp mastodon_type("Note"), do: "mention"
  defp mastodon_type(type) when is_binary(type), do: String.downcase(type)
  defp mastodon_type(_), do: "unknown"

  defp account_for_actor(actor_ap_id) when is_binary(actor_ap_id) do
    Users.get_by_ap_id(actor_ap_id) ||
      %{ap_id: actor_ap_id, nickname: Fallback.fallback_username(actor_ap_id)}
  end

  defp account_for_actor(_), do: %{ap_id: "unknown", nickname: "unknown"}

  defp format_datetime(%Object{published: %DateTime{} = dt}) do
    DateTime.to_iso8601(dt)
  end

  defp format_datetime(%Object{inserted_at: %DateTime{} = dt}) do
    DateTime.to_iso8601(dt)
  end

  defp format_datetime(%Object{inserted_at: %NaiveDateTime{} = dt}) do
    dt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp format_datetime(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp rendering_context(activities, current_user) when is_list(activities) do
    actor_ap_ids =
      activities
      |> Enum.map(&Map.get(&1, :actor))
      |> normalize_ap_ids()

    users_by_ap_id =
      actor_ap_ids
      |> Users.list_by_ap_ids()
      |> Map.new(&{&1.ap_id, &1})

    followers_counts = Relationships.count_by_type_objects("Follow", actor_ap_ids)
    following_counts = Relationships.count_by_type_actors("Follow", actor_ap_ids)
    statuses_counts = Objects.count_notes_by_actors(actor_ap_ids)

    accounts_by_actor =
      Enum.reduce(actor_ap_ids, %{}, fn ap_id, acc ->
        account =
          case Map.get(users_by_ap_id, ap_id) do
            %User{} = user ->
              AccountRenderer.render_account(user,
                followers_count: Map.get(followers_counts, ap_id, 0),
                following_count: Map.get(following_counts, ap_id, 0),
                statuses_count: Map.get(statuses_counts, ap_id, 0)
              )

            _ ->
              AccountRenderer.render_account(%{
                ap_id: ap_id,
                nickname: Fallback.fallback_username(ap_id)
              })
          end

        Map.put(acc, ap_id, account)
      end)

    status_target_ap_ids =
      activities
      |> Enum.filter(&match?(%Object{}, &1))
      |> Enum.filter(&(&1.type in @status_object_types))
      |> Enum.map(&Map.get(&1, :object))
      |> normalize_ap_ids()

    status_targets = Objects.list_by_ap_ids(status_target_ap_ids)

    status_objects =
      activities
      |> Enum.filter(&match?(%Object{}, &1))
      |> Enum.filter(&(&1.type == "Note"))
      |> Kernel.++(status_targets)
      |> Enum.uniq_by(&Map.get(&1, :ap_id))

    rendered_statuses =
      case status_objects do
        [] -> []
        _ -> StatusRenderer.render_statuses(status_objects, current_user)
      end

    rendered_statuses_by_ap_id =
      status_objects
      |> Enum.zip(rendered_statuses)
      |> Enum.reduce(%{}, fn
        {%Object{ap_id: ap_id}, rendered}, acc when is_binary(ap_id) ->
          Map.put(acc, ap_id, rendered)

        _other, acc ->
          acc
      end)

    notifications_last_seen_id =
      case current_user do
        %User{} = user -> Map.get(user, :notifications_last_seen_id)
        _ -> nil
      end

    %{
      current_user: current_user,
      notifications_last_seen_id: notifications_last_seen_id,
      accounts_by_actor: accounts_by_actor,
      rendered_statuses_by_ap_id: rendered_statuses_by_ap_id
    }
  end

  defp render_notification_with_context(%Object{} = activity, ctx) do
    status =
      case activity do
        %Object{type: "Note"} ->
          Map.get(ctx.rendered_statuses_by_ap_id, activity.ap_id)

        %Object{type: type, object: object_ap_id} when type in @status_object_types ->
          object_ap_id = if is_binary(object_ap_id), do: String.trim(object_ap_id), else: nil

          if is_binary(object_ap_id) and object_ap_id != "" do
            Map.get(ctx.rendered_statuses_by_ap_id, object_ap_id)
          end

        _ ->
          nil
      end

    %{
      "id" => notification_id(activity),
      "type" => mastodon_type(activity.type),
      "created_at" => format_datetime(activity),
      "account" => account_from_context(activity.actor, ctx),
      "status" => status,
      "pleroma" => %{
        "is_seen" => seen?(activity, ctx.notifications_last_seen_id)
      }
    }
  end

  defp render_notification_with_context(_activity, ctx) do
    %{
      "id" => "unknown",
      "type" => "unknown",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "account" => account_from_context(nil, ctx),
      "status" => nil,
      "pleroma" => %{"is_seen" => false}
    }
  end

  defp account_from_context(actor_ap_id, ctx) when is_binary(actor_ap_id) do
    actor_ap_id = String.trim(actor_ap_id)

    if actor_ap_id == "" do
      account_from_context(nil, ctx)
    else
      case Map.get(ctx.accounts_by_actor, actor_ap_id) do
        %{} = account ->
          account

        _ ->
          AccountRenderer.render_account(%{
            ap_id: actor_ap_id,
            nickname: Fallback.fallback_username(actor_ap_id)
          })
      end
    end
  end

  defp account_from_context(_actor_ap_id, _ctx) do
    AccountRenderer.render_account(%{ap_id: "unknown", nickname: "unknown"})
  end

  defp notification_id(%Object{id: id}) when is_binary(id) and id != "", do: id
  defp notification_id(_activity), do: "unknown"

  defp seen?(%Object{} = activity, last_seen_id) when is_binary(last_seen_id) do
    activity_id = Map.get(activity, :id)

    with true <- is_binary(activity_id),
         true <- flake_id?(activity_id),
         true <- flake_id?(last_seen_id),
         <<_::128>> = activity_bin <- FlakeId.from_string(activity_id),
         <<_::128>> = last_seen_bin <- FlakeId.from_string(last_seen_id) do
      activity_bin <= last_seen_bin
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp seen?(_activity, _last_seen_id), do: false

  defp flake_id?(id) when is_binary(id) do
    id = String.trim(id)

    cond do
      id == "" ->
        false

      byte_size(id) < 18 ->
        false

      true ->
        try do
          match?(<<_::128>>, FlakeId.from_string(id))
        rescue
          _ -> false
        end
    end
  end

  defp flake_id?(_id), do: false

  defp normalize_ap_ids(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_ap_ids(_), do: []
end
