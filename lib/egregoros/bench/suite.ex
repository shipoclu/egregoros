defmodule Egregoros.Bench.Suite do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Egregoros.Notifications
  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Repo
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.MastodonAPI.StatusRenderer
  alias EgregorosWeb.ViewModels.Status, as: StatusVM

  def default_cases do
    current_user = pick_local_user()
    no_follows_user = Users.get_by_nickname("edge_nofollows")
    dormant_user = Users.get_by_nickname("edge_dormant")
    reply_parent_ap_ids = pick_parent_note_ap_ids_with_replies(20)

    [
      %{
        name: "timeline.public.list_notes(limit=20)",
        fun: fn -> Objects.list_notes(limit: 20) end
      },
      %{
        name: "timeline.public.list_public_statuses(limit=20)",
        fun: fn -> Objects.list_public_statuses(limit: 20) end
      },
      %{
        name: "timeline.public.list_public_statuses(limit=20, only_media=true)",
        fun: fn -> Objects.list_public_statuses(limit: 20, only_media: true) end
      },
      %{
        name: "timeline.home.list_home_notes(limit=20)",
        fun: fn ->
          case current_user do
            %User{} = user -> Objects.list_home_notes(user.ap_id, limit: 20)
            _ -> []
          end
        end
      },
      %{
        name: "timeline.home.list_home_statuses(limit=20)",
        fun: fn ->
          case current_user do
            %User{} = user -> Objects.list_home_statuses(user.ap_id, limit: 20)
            _ -> []
          end
        end
      },
      %{
        name: "timeline.home.edge_nofollows.list_home_statuses(limit=20)",
        fun: fn ->
          case no_follows_user do
            %User{} = user -> Objects.list_home_statuses(user.ap_id, limit: 20)
            _ -> []
          end
        end
      },
      %{
        name: "timeline.home.edge_dormant.list_home_statuses(limit=20)",
        fun: fn ->
          case dormant_user do
            %User{} = user -> Objects.list_home_statuses(user.ap_id, limit: 20)
            _ -> []
          end
        end
      },
      %{
        name: "timeline.tag.list_public_statuses_by_hashtag(tag='bench', limit=20)",
        fun: fn -> Objects.list_public_statuses_by_hashtag("bench", limit: 20) end
      },
      %{
        name:
          "timeline.tag.list_public_statuses_by_hashtag(tag='bench', limit=20, only_media=true)",
        fun: fn ->
          Objects.list_public_statuses_by_hashtag("bench", limit: 20, only_media: true)
        end
      },
      %{
        name: "timeline.tag.list_public_statuses_by_hashtag(tag='rare', limit=20)",
        fun: fn -> Objects.list_public_statuses_by_hashtag("rare", limit: 20) end
      },
      %{
        name: "timeline.tag.list_public_statuses_by_hashtag(tag='missing', limit=20)",
        fun: fn -> Objects.list_public_statuses_by_hashtag("missing", limit: 20) end
      },
      %{
        name: "thread.count_note_replies_by_parent_ap_ids(parent_count=20)",
        fun: fn ->
          Objects.count_note_replies_by_parent_ap_ids(reply_parent_ap_ids) |> Map.to_list()
        end
      },
      %{
        name: "render.status_vm.decorate_many(20)",
        fun: fn ->
          objects = Objects.list_notes(limit: 20)
          StatusVM.decorate_many(objects, current_user)
        end
      },
      %{
        name: "render.mastodon.statuses.render(20)",
        fun: fn ->
          objects = Objects.list_notes(limit: 20)
          StatusRenderer.render_statuses(objects, current_user)
        end
      },
      %{
        name: "search.users(query='local')",
        fun: fn -> Users.search("local", limit: 20) end
      },
      %{
        name: "search.notes(query='bench')",
        fun: fn -> Objects.search_notes("bench", limit: 20) end
      },
      %{
        name: "notifications.list_for_user(limit=20)",
        fun: fn ->
          case current_user do
            %User{} = user -> Notifications.list_for_user(user, limit: 20)
            _ -> []
          end
        end
      }
    ]
  end

  defp pick_parent_note_ap_ids_with_replies(limit) when is_integer(limit) and limit > 0 do
    from(o in Object,
      where: o.type == "Note" and not is_nil(o.in_reply_to_ap_id),
      distinct: o.in_reply_to_ap_id,
      limit: ^limit,
      select: o.in_reply_to_ap_id
    )
    |> Repo.all()
  end

  defp pick_parent_note_ap_ids_with_replies(_limit), do: []

  defp pick_local_user do
    from(u in User,
      where: u.local == true and u.nickname not in ["edge_nofollows", "edge_dormant"],
      order_by: [asc: u.id],
      limit: 1
    )
    |> Repo.one()
    |> case do
      %User{} = user ->
        user

      _ ->
        from(u in User, where: u.local == true, order_by: [asc: u.id], limit: 1)
        |> Repo.one()
    end
  end
end
