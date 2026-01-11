defmodule EgregorosWeb.PleromaAPI.NotificationsController do
  use EgregorosWeb, :controller

  def read(conn, _params) do
    json(conn, %{"status" => "success"})
  end
end

