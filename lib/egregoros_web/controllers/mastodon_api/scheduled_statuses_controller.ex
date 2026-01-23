defmodule EgregorosWeb.MastodonAPI.ScheduledStatusesController do
  use EgregorosWeb, :controller

  alias Egregoros.ScheduledStatuses
  alias EgregorosWeb.MastodonAPI.Pagination
  alias EgregorosWeb.MastodonAPI.ScheduledStatusRenderer

  def index(conn, params) do
    user = conn.assigns.current_user
    pagination = Pagination.parse(params)

    scheduled_statuses =
      ScheduledStatuses.list_pending_for_user(user,
        limit: pagination.limit + 1,
        max_id: pagination.max_id,
        since_id: pagination.since_id
      )

    has_more? = length(scheduled_statuses) > pagination.limit
    scheduled_statuses = Enum.take(scheduled_statuses, pagination.limit)

    conn
    |> Pagination.maybe_put_links(scheduled_statuses, has_more?, pagination)
    |> json(ScheduledStatusRenderer.render_scheduled_statuses(scheduled_statuses, user))
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case ScheduledStatuses.get_pending_for_user(user, id) do
      nil ->
        send_resp(conn, 404, "Not Found")

      scheduled_status ->
        json(conn, ScheduledStatusRenderer.render_scheduled_status(scheduled_status, user))
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    scheduled_at = Map.get(params, "scheduled_at")

    case ScheduledStatuses.update_scheduled_at(user, id, %{"scheduled_at" => scheduled_at}) do
      {:ok, scheduled_status} ->
        json(conn, ScheduledStatusRenderer.render_scheduled_status(scheduled_status, user))

      {:error, :not_found} ->
        send_resp(conn, 404, "Not Found")

      {:error, _} ->
        send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case ScheduledStatuses.delete(user, id) do
      {:ok, scheduled_status} ->
        json(conn, ScheduledStatusRenderer.render_scheduled_status(scheduled_status, user))

      {:error, :not_found} ->
        send_resp(conn, 404, "Not Found")

      {:error, _} ->
        send_resp(conn, 422, "Unprocessable Entity")
    end
  end
end
