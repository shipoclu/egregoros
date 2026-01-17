defmodule EgregorosWeb.MastodonAPI.SuggestionsController do
  use EgregorosWeb, :controller

  import Ecto.Query

  alias Egregoros.Relationship
  alias Egregoros.Repo
  alias Egregoros.User
  alias EgregorosWeb.MastodonAPI.AccountRenderer

  @default_limit 20
  @max_limit 80
  @system_nicknames ["internal.fetch", "instance.actor"]
  @exclusion_relationship_types ["Follow", "FollowRequest", "Block", "Mute"]

  def index(conn, params) do
    %User{} = actor = conn.assigns.current_user
    limit = params |> Map.get("limit") |> parse_limit()

    accounts =
      actor
      |> list_suggestions(limit)
      |> Enum.map(&AccountRenderer.render_account/1)

    json(conn, accounts)
  end

  defp list_suggestions(%User{ap_id: actor_ap_id}, limit)
       when is_binary(actor_ap_id) and actor_ap_id != "" and is_integer(limit) do
    followed_subquery =
      from(r in Relationship,
        where: r.type == "Follow" and r.actor == ^actor_ap_id,
        distinct: r.object,
        select: r.object
      )

    candidate_counts =
      from(r in Relationship,
        where: r.type == "Follow" and r.actor in subquery(followed_subquery),
        group_by: r.object,
        select: %{ap_id: r.object, mutuals: count(r.id)}
      )

    candidates =
      from(u in User,
        join: c in subquery(candidate_counts),
        on: c.ap_id == u.ap_id,
        left_join: ex in Relationship,
        on:
          ex.actor == ^actor_ap_id and ex.object == u.ap_id and
            ex.type in ^@exclusion_relationship_types,
        where: is_nil(ex.id),
        where: u.ap_id != ^actor_ap_id,
        where: u.nickname not in ^@system_nicknames,
        order_by: [desc: c.mutuals, desc_nulls_last: u.last_activity_at, asc: u.nickname],
        limit: ^limit
      )
      |> Repo.all()

    if length(candidates) < limit do
      needed = limit - length(candidates)
      exclude_ap_ids = [actor_ap_id | Enum.map(candidates, & &1.ap_id)]

      fallback =
        from(u in User,
          left_join: ex in Relationship,
          on:
            ex.actor == ^actor_ap_id and ex.object == u.ap_id and
              ex.type in ^@exclusion_relationship_types,
          where: is_nil(ex.id),
          where: u.local == true,
          where: u.ap_id != ^actor_ap_id,
          where: u.ap_id not in ^exclude_ap_ids,
          where: u.nickname not in ^@system_nicknames,
          order_by: [desc_nulls_last: u.last_activity_at, desc: u.inserted_at, asc: u.nickname],
          limit: ^needed
        )
        |> Repo.all()

      candidates ++ fallback
    else
      candidates
    end
  end

  defp list_suggestions(_actor, _limit), do: []

  defp parse_limit(nil), do: @default_limit

  defp parse_limit(value) when is_integer(value) do
    value
    |> max(1)
    |> min(@max_limit)
  end

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> parse_limit(int)
      _ -> @default_limit
    end
  end

  defp parse_limit(_value), do: @default_limit
end
