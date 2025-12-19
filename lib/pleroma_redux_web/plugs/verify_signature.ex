defmodule PleromaReduxWeb.Plugs.VerifySignature do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case PleromaRedux.Signature.verify_request(conn) do
      :ok ->
        conn

      {:error, _reason} ->
        conn
        |> send_resp(401, "Unauthorized")
        |> halt()
    end
  end
end
