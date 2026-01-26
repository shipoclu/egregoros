defmodule EgregorosWeb.MastodonAPI.DirectoryController do
  use EgregorosWeb, :controller

  import Ecto.Query

  alias Egregoros.Config
  alias Egregoros.Repo
  alias Egregoros.User
  alias EgregorosWeb.MastodonAPI.AccountRenderer

  @default_limit 20
  @max_limit 80
  @system_nicknames ["internal.fetch", "instance.actor"]

  def index(conn, params) do
    if Config.get(:profile_directory, true) do
      current_user_id =
        case conn.assigns[:current_user] do
          %User{id: id} when is_binary(id) -> id
          _ -> nil
        end

      limit = params |> Map.get("limit") |> parse_limit()
      offset = params |> Map.get("offset") |> parse_offset()
      order = params |> Map.get("order") |> parse_order()
      local_only? = params |> Map.get("local") |> parse_local_only()

      query =
        from(u in User,
          where: u.nickname not in ^@system_nicknames,
          limit: ^limit,
          offset: ^offset
        )
        |> maybe_where_local(local_only?)
        |> maybe_where_not_id(current_user_id)
        |> apply_order(order)

      accounts =
        query
        |> Repo.all()
        |> Enum.map(&AccountRenderer.render_account/1)

      json(conn, accounts)
    else
      json(conn, [])
    end
  end

  defp maybe_where_local(query, true), do: from(u in query, where: u.local == true)
  defp maybe_where_local(query, false), do: query

  defp maybe_where_not_id(query, id) when is_binary(id), do: from(u in query, where: u.id != ^id)
  defp maybe_where_not_id(query, _id), do: query

  defp apply_order(query, :new), do: from(u in query, order_by: [desc: u.inserted_at, desc: u.id])

  defp apply_order(query, _order) do
    from(u in query,
      order_by: [desc_nulls_last: u.last_activity_at, desc: u.inserted_at, desc: u.id]
    )
  end

  defp parse_order(nil), do: :active

  defp parse_order(value) do
    case value |> to_string() |> String.trim() do
      "new" -> :new
      _ -> :active
    end
  end

  defp parse_local_only(nil), do: true
  defp parse_local_only(value), do: value in [true, "true"]

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

  defp parse_offset(nil), do: 0

  defp parse_offset(value) when is_integer(value), do: max(value, 0)

  defp parse_offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> parse_offset(int)
      _ -> 0
    end
  end

  defp parse_offset(_value), do: 0
end
