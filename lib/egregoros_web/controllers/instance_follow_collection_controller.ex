defmodule EgregorosWeb.InstanceFollowCollectionController do
  use EgregorosWeb, :controller

  alias Egregoros.Federation.InstanceActor
  alias Egregoros.Relationships

  def followers(conn, _params) do
    case InstanceActor.get_actor() do
      {:ok, user} ->
        items =
          user.ap_id
          |> Relationships.list_follows_to()
          |> Enum.map(& &1.actor)

        respond_collection(conn, user.ap_id <> "/followers", items)

      {:error, _reason} ->
        send_resp(conn, 500, "Internal Server Error")
    end
  end

  def following(conn, _params) do
    case InstanceActor.get_actor() do
      {:ok, user} ->
        items =
          user.ap_id
          |> Relationships.list_follows_by_actor()
          |> Enum.map(& &1.object)

        respond_collection(conn, user.ap_id <> "/following", items)

      {:error, _reason} ->
        send_resp(conn, 500, "Internal Server Error")
    end
  end

  defp respond_collection(conn, id, items) do
    payload = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => id,
      "type" => "OrderedCollection",
      "totalItems" => length(items),
      "orderedItems" => items
    }

    conn
    |> put_resp_content_type("application/activity+json")
    |> send_resp(200, Jason.encode!(payload))
  end
end
