defmodule Egregoros.Auth do
  @callback current_user(Plug.Conn.t()) :: {:ok, Egregoros.User.t()} | {:error, term()}

  def current_user(conn) do
    impl().current_user(conn)
  end

  defp impl do
    Application.get_env(:egregoros, __MODULE__, Egregoros.Auth.Default)
  end
end
