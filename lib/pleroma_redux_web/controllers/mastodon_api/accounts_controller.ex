defmodule PleromaReduxWeb.MastodonAPI.AccountsController do
  use PleromaReduxWeb, :controller

  alias PleromaRedux.Objects
  alias PleromaRedux.Pipeline
  alias PleromaRedux.Users
  alias PleromaReduxWeb.MastodonAPI.AccountRenderer
  alias PleromaReduxWeb.Endpoint

  def verify_credentials(conn, _params) do
    json(conn, AccountRenderer.render_account(conn.assigns.current_user))
  end

  def show(conn, %{"id" => id}) do
    case Users.get(id) do
      nil -> send_resp(conn, 404, "Not Found")
      user -> json(conn, AccountRenderer.render_account(user))
    end
  end

  def follow(conn, %{"id" => id}) do
    with %{} = target <- Users.get(id),
         {:ok, _follow} <-
           Pipeline.ingest(build_activity("Follow", conn.assigns.current_user.ap_id, target.ap_id),
             local: true
           ) do
      json(conn, AccountRenderer.render_account(target))
    else
      nil -> send_resp(conn, 404, "Not Found")
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def unfollow(conn, %{"id" => id}) do
    with %{} = target <- Users.get(id),
         %{} =
           follow <-
             Objects.get_by_type_actor_object("Follow", conn.assigns.current_user.ap_id, target.ap_id),
         {:ok, _undo} <-
           Pipeline.ingest(build_activity("Undo", conn.assigns.current_user.ap_id, follow.ap_id),
             local: true
           ) do
      json(conn, AccountRenderer.render_account(target))
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
