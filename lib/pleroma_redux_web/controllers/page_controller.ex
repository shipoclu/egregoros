defmodule PleromaReduxWeb.PageController do
  use PleromaReduxWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
