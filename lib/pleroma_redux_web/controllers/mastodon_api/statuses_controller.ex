defmodule PleromaReduxWeb.MastodonAPI.StatusesController do
  use PleromaReduxWeb, :controller

  alias PleromaRedux.Objects
  alias PleromaRedux.Pipeline
  alias PleromaRedux.Publish
  alias PleromaReduxWeb.Endpoint
  alias PleromaReduxWeb.MastodonAPI.StatusRenderer

  def create(conn, %{"status" => status}) do
    status = String.trim(status || "")

    if status == "" do
      send_resp(conn, 422, "Unprocessable Entity")
    else
      user = conn.assigns.current_user

      with {:ok, create_object} <- Publish.post_note(user, status),
           %{} = object <- Objects.get_by_ap_id(create_object.object) do
        json(conn, StatusRenderer.render_status(object, user))
      end
    end
  end

  def create(conn, _params) do
    send_resp(conn, 422, "Unprocessable Entity")
  end

  def show(conn, %{"id" => id}) do
    case Objects.get(id) do
      nil ->
        send_resp(conn, 404, "Not Found")

      object ->
        json(conn, StatusRenderer.render_status(object))
    end
  end

  def favourite(conn, %{"id" => id}) do
    with %{} = object <- Objects.get(id),
         {:ok, _liked} <-
           Pipeline.ingest(build_activity("Like", conn.assigns.current_user.ap_id, object.ap_id), local: true) do
      json(conn, StatusRenderer.render_status(object, conn.assigns.current_user))
    else
      nil -> send_resp(conn, 404, "Not Found")
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def unfavourite(conn, %{"id" => id}) do
    with %{} = object <- Objects.get(id),
         %{} = like <- Objects.get_by_type_actor_object("Like", conn.assigns.current_user.ap_id, object.ap_id),
         {:ok, _undo} <- Pipeline.ingest(build_activity("Undo", conn.assigns.current_user.ap_id, like.ap_id), local: true) do
      json(conn, StatusRenderer.render_status(object, conn.assigns.current_user))
    else
      nil -> send_resp(conn, 404, "Not Found")
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def reblog(conn, %{"id" => id}) do
    with %{} = object <- Objects.get(id),
         {:ok, _announce} <- Pipeline.ingest(build_activity("Announce", conn.assigns.current_user.ap_id, object.ap_id), local: true) do
      json(conn, StatusRenderer.render_status(object, conn.assigns.current_user))
    else
      nil -> send_resp(conn, 404, "Not Found")
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def unreblog(conn, %{"id" => id}) do
    with %{} = object <- Objects.get(id),
         %{} = announce <- Objects.get_by_type_actor_object("Announce", conn.assigns.current_user.ap_id, object.ap_id),
         {:ok, _undo} <- Pipeline.ingest(build_activity("Undo", conn.assigns.current_user.ap_id, announce.ap_id), local: true) do
      json(conn, StatusRenderer.render_status(object, conn.assigns.current_user))
    else
      nil -> send_resp(conn, 404, "Not Found")
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  defp build_activity(type, actor, object) do
    %{
      "id" => Endpoint.url() <> "/activities/" <> String.downcase(type) <> "/" <> Ecto.UUID.generate(),
      "type" => type,
      "actor" => actor,
      "object" => object,
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
