defmodule Egregoros.AuthZ do
  @callback authorize(Plug.Conn.t(), [String.t()]) :: :ok | {:error, term()}

  def authorize(conn, required_scopes) when is_list(required_scopes) do
    impl().authorize(conn, required_scopes)
  end

  defp impl do
    Egregoros.Config.get(__MODULE__, Egregoros.AuthZ.OAuthScopes)
  end
end
