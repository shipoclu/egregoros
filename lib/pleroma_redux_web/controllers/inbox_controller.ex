defmodule PleromaReduxWeb.InboxController do
  use PleromaReduxWeb, :controller

  plug PleromaReduxWeb.Plugs.VerifySignature

  alias PleromaRedux.Users
  alias PleromaRedux.Workers.IngestActivity

  def inbox(conn, %{"nickname" => nickname}) do
    with %{} <- Users.get_by_nickname(nickname),
         activity when is_map(activity) <- conn.body_params,
         {:ok, _job} <- Oban.insert(IngestActivity.new(%{"activity" => activity})) do
      send_resp(conn, 202, "")
    else
      nil -> send_resp(conn, 404, "Not Found")
      {:error, _changeset} -> send_resp(conn, 500, "Internal Server Error")
      _ -> send_resp(conn, 400, "Bad Request")
    end
  end
end
