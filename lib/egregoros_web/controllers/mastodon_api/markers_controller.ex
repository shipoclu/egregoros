defmodule EgregorosWeb.MastodonAPI.MarkersController do
  use EgregorosWeb, :controller

  alias Egregoros.Marker
  alias Egregoros.Markers

  def index(conn, params) do
    user = conn.assigns.current_user

    timelines =
      params
      |> Map.get("timeline", [])
      |> List.wrap()

    markers =
      user
      |> Markers.list_for_user(timelines)
      |> render_markers()

    json(conn, markers)
  end

  def create(conn, params) do
    user = conn.assigns.current_user

    updates =
      params
      |> Enum.flat_map(fn
        {timeline, %{"last_read_id" => last_read_id}} ->
          [{to_string(timeline), to_string(last_read_id)}]

        _ ->
          []
      end)

    case Markers.upsert_many(user, updates) do
      {:ok, markers} ->
        json(conn, render_markers(markers))

      {:error, _} ->
        send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  defp render_markers(markers) when is_list(markers) do
    Map.new(markers, fn %Marker{} = marker ->
      {marker.timeline, render_marker(marker)}
    end)
  end

  defp render_markers(_), do: %{}

  defp render_marker(%Marker{} = marker) do
    %{
      "last_read_id" => marker.last_read_id,
      "version" => marker.version,
      "updated_at" => DateTime.to_iso8601(marker.updated_at)
    }
  end
end
