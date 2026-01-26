defmodule EgregorosWeb.ActivityController do
  use EgregorosWeb, :controller

  alias Egregoros.Objects
  alias EgregorosWeb.Endpoint

  def show(conn, %{"uuid" => uuid}) do
    ap_id = Endpoint.url() <> "/activities/" <> uuid
    serve_activity(conn, ap_id)
  end

  def show_typed(conn, %{"type" => type, "uuid" => uuid}) do
    ap_id = Endpoint.url() <> "/activities/" <> type <> "/" <> uuid
    serve_activity(conn, ap_id)
  end

  defp serve_activity(conn, ap_id) when is_binary(ap_id) do
    case Objects.get_by_ap_id(ap_id) do
      %{local: true} = object ->
        if Objects.publicly_visible?(object) do
          data = Map.put_new(object.data, "@context", "https://www.w3.org/ns/activitystreams")

          conn
          |> put_resp_content_type("application/activity+json")
          |> send_resp(200, Jason.encode!(data))
        else
          send_resp(conn, 404, "Not found")
        end

      _ ->
        send_resp(conn, 404, "Not found")
    end
  end
end
