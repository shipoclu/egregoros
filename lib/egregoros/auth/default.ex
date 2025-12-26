defmodule Egregoros.Auth.Default do
  @behaviour Egregoros.Auth

  alias Egregoros.Users

  @impl true
  def current_user(_conn) do
    Users.get_or_create_local_user("local")
  end
end
