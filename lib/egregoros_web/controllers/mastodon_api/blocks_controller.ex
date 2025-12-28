defmodule EgregorosWeb.MastodonAPI.BlocksController do
  use EgregorosWeb, :controller

  alias Egregoros.Relationships
  alias Egregoros.Users
  alias EgregorosWeb.MastodonAPI.AccountRenderer
  alias EgregorosWeb.MastodonAPI.Pagination

  def index(conn, params) do
    pagination = Pagination.parse(params)
    current_user = conn.assigns.current_user

    relationships =
      Relationships.list_by_type_actor("Block", current_user.ap_id,
        limit: pagination.limit + 1,
        max_id: pagination.max_id
      )

    has_more? = length(relationships) > pagination.limit
    relationships = Enum.take(relationships, pagination.limit)

    users =
      relationships
      |> Enum.map(& &1.object)
      |> Users.list_by_ap_ids()
      |> Map.new(fn user -> {user.ap_id, user} end)

    accounts =
      relationships
      |> Enum.flat_map(fn relationship ->
        case Map.get(users, relationship.object) do
          %{} = user -> [AccountRenderer.render_account(user)]
          _ -> []
        end
      end)

    conn
    |> Pagination.maybe_put_links(relationships, has_more?, pagination)
    |> json(accounts)
  end
end

