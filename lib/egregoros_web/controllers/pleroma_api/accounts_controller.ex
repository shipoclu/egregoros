defmodule EgregorosWeb.PleromaAPI.AccountsController do
  use EgregorosWeb, :controller

  alias Egregoros.Objects
  alias Egregoros.Relationships
  alias Egregoros.Users
  alias EgregorosWeb.MastodonAPI.Pagination
  alias EgregorosWeb.MastodonAPI.StatusRenderer

  @status_types ~w(Note Announce)

  def favourites(conn, %{"id" => id} = params) do
    case Users.get(id) do
      nil ->
        send_resp(conn, 404, "Not Found")

      user ->
        pagination = Pagination.parse(params)
        viewer = conn.assigns[:current_user]

        relationships =
          Relationships.list_by_type_actor("Like", user.ap_id,
            limit: pagination.limit + 1,
            max_id: pagination.max_id
          )

        has_more? = length(relationships) > pagination.limit
        relationships = Enum.take(relationships, pagination.limit)
        objects = objects_for_relationships(relationships, viewer)

        conn
        |> Pagination.maybe_put_links(relationships, has_more?, pagination)
        |> json(StatusRenderer.render_statuses(objects, viewer))
    end
  end

  def scrobbles(conn, %{"id" => id}) do
    case Users.get(id) do
      nil -> send_resp(conn, 404, "Not Found")
      _user -> json(conn, [])
    end
  end

  defp objects_for_relationships(relationships, viewer) when is_list(relationships) do
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
    |> Enum.filter(&(&1.type in @status_types))
    |> Enum.filter(&Objects.visible_to?(&1, viewer))
  end
end

