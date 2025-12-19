defmodule PleromaReduxWeb.MastodonAPI.TimelinesController do
  use PleromaReduxWeb, :controller

  alias PleromaRedux.Objects
  alias PleromaReduxWeb.MastodonAPI.StatusRenderer

  def public(conn, _params) do
    objects = Objects.list_notes()
    json(conn, StatusRenderer.render_statuses(objects))
  end

  def home(conn, _params) do
    user = conn.assigns.current_user
    objects = Objects.list_home_notes(user.ap_id)
    json(conn, StatusRenderer.render_statuses(objects))
  end
end
