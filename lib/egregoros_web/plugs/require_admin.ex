defmodule EgregorosWeb.Plugs.RequireAdmin do
  import Plug.Conn
  import Phoenix.Controller

  alias Egregoros.User

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns.current_user do
      %User{admin: true} ->
        conn

      nil ->
        conn
        |> redirect(to: "/login")
        |> halt()

      _ ->
        conn
        |> send_resp(403, "Forbidden")
        |> halt()
    end
  end
end
