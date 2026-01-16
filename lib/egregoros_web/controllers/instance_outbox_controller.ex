defmodule EgregorosWeb.InstanceOutboxController do
  use EgregorosWeb, :controller

  alias Egregoros.Federation.InstanceActor

  def outbox(conn, _params) do
    case InstanceActor.get_actor() do
      {:ok, user} ->
        payload = %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => user.outbox,
          "type" => "OrderedCollection",
          "totalItems" => 0,
          "orderedItems" => []
        }

        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(200, Jason.encode!(payload))

      {:error, _reason} ->
        send_resp(conn, 500, "Internal Server Error")
    end
  end
end
