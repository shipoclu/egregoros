defmodule EgregorosWeb.PleromaFrontendConfigurationsController do
  use EgregorosWeb, :controller

  def index(conn, _params) do
    json(conn, %{"pleroma_fe" => %{}})
  end
end
