defmodule EgregorosWeb.MastodonAPI.AnnouncementsController do
  use EgregorosWeb, :controller

  def index(conn, _params) do
    json(conn, [])
  end

  def dismiss(conn, _params) do
    json(conn, %{})
  end
end

