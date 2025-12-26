defmodule EgregorosWeb.Plugs.RequireAuth do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Egregoros.Auth.current_user(conn) do
      {:ok, user} ->
        assign(conn, :current_user, user)

      {:error, _reason} ->
        conn
        |> send_resp(401, "Unauthorized")
        |> halt()
    end
  end
end
