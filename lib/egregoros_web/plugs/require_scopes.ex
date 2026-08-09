defmodule EgregorosWeb.Plugs.RequireScopes do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, required_scopes) when is_list(required_scopes) do
    case Egregoros.AuthZ.authorize(conn, required_scopes) do
      :ok ->
        conn

      {:error, :unauthorized} ->
        conn
        |> send_resp(401, "Unauthorized")
        |> halt()

      {:error, :insufficient_scope} ->
        conn
        |> send_resp(403, "Forbidden")
        |> halt()

      {:error, _} ->
        conn
        |> send_resp(403, "Forbidden")
        |> halt()
    end
  end

  def call(conn, {:any, required_scopes}) when is_list(required_scopes) do
    results = Enum.map(required_scopes, &Egregoros.AuthZ.authorize(conn, [&1]))

    cond do
      :ok in results ->
        conn

      Enum.all?(results, &(&1 == {:error, :unauthorized})) ->
        conn
        |> send_resp(401, "Unauthorized")
        |> halt()

      true ->
        conn
        |> send_resp(403, "Forbidden")
        |> halt()
    end
  end

  def call(conn, _opts) do
    conn
    |> send_resp(500, "Invalid scope configuration")
    |> halt()
  end
end
