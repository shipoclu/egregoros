defmodule Egregoros.Auth.BearerToken do
  @behaviour Egregoros.Auth

  import Plug.Conn, only: [get_req_header: 2]

  alias Egregoros.OAuth
  alias Egregoros.OAuth.Token
  alias Egregoros.User

  def access_token(conn) do
    bearer_token(conn)
  end

  @impl true
  def current_user(conn) do
    case access_token(conn) do
      nil ->
        {:error, :unauthorized}

      token ->
        with %Token{user: %User{} = user} <- OAuth.get_token(token) do
          {:ok, user}
        else
          _ -> {:error, :unauthorized}
        end
    end
  end

  defp bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> to_string()
    |> String.split(" ", parts: 2)
    |> case do
      ["Bearer", token] when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end
end
