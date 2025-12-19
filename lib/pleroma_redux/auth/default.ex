defmodule PleromaRedux.Auth.Default do
  @behaviour PleromaRedux.Auth

  alias PleromaRedux.Users

  @impl true
  def current_user(_conn) do
    Users.get_or_create_local_user("local")
  end
end
