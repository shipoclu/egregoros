defmodule PleromaRedux.Auth do
  @callback current_user(Plug.Conn.t()) :: {:ok, PleromaRedux.User.t()} | {:error, term()}

  def current_user(conn) do
    impl().current_user(conn)
  end

  defp impl do
    Application.get_env(:pleroma_redux, __MODULE__, PleromaRedux.Auth.Default)
  end
end
