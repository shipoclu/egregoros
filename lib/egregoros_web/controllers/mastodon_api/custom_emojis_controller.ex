defmodule EgregorosWeb.MastodonAPI.CustomEmojisController do
  use EgregorosWeb, :controller

  def index(conn, _params) do
    json(conn, [])
  end
end
