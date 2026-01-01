defmodule EgregorosWeb.MastodonAPI.FavouritesController do
  use EgregorosWeb, :controller

  alias Egregoros.Objects
  alias Egregoros.Relationships
  alias EgregorosWeb.MastodonAPI.Pagination
  alias EgregorosWeb.MastodonAPI.StatusRenderer

  def index(conn, params) do
    user = conn.assigns.current_user
    pagination = Pagination.parse(params)

    relationships =
      Relationships.list_by_type_actor("Like", user.ap_id,
        limit: pagination.limit + 1,
        max_id: pagination.max_id
      )

    has_more? = length(relationships) > pagination.limit
    relationships = Enum.take(relationships, pagination.limit)
    objects = objects_for_relationships(relationships, user)

    conn
    |> Pagination.maybe_put_links(relationships, has_more?, pagination)
    |> json(StatusRenderer.render_statuses(objects, user))
  end

  defp objects_for_relationships(relationships, user) when is_list(relationships) do
    ap_ids =
      relationships
      |> Enum.map(& &1.object)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    objects_by_ap_id =
      ap_ids
      |> Objects.list_by_ap_ids()
      |> Map.new(&{&1.ap_id, &1})

    relationships
    |> Enum.map(&Map.get(objects_by_ap_id, &1.object))
    |> Enum.filter(&match?(%{}, &1))
    |> Enum.filter(&Objects.visible_to?(&1, user))
  end
end
