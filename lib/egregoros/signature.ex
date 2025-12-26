defmodule Egregoros.Signature do
  @callback verify_request(Plug.Conn.t()) :: {:ok, binary()} | {:error, term()}

  def verify_request(conn) do
    impl().verify_request(conn)
  end

  defp impl do
    Application.get_env(:egregoros, __MODULE__, Egregoros.Signature.HTTP)
  end
end
