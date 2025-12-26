defmodule EgregorosWeb.Plugs.FetchCurrentUser do
  import Plug.Conn

  alias Egregoros.Users

  def init(opts), do: opts

  def call(conn, _opts) do
    user =
      case get_session(conn, :user_id) do
        nil -> nil
        id -> Users.get(id)
      end

    assign(conn, :current_user, user)
  end
end
