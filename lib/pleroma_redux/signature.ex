defmodule PleromaRedux.Signature do
  @callback verify_request(Plug.Conn.t()) :: {:ok, binary()} | {:error, term()}

  def verify_request(conn) do
    impl().verify_request(conn)
  end

  defp impl do
    Application.get_env(:pleroma_redux, __MODULE__, PleromaRedux.Signature.HTTP)
  end
end
