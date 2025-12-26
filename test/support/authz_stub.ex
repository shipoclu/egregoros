defmodule Egregoros.AuthZ.Stub do
  @behaviour Egregoros.AuthZ

  @impl true
  def authorize(_conn, _required_scopes) do
    :ok
  end
end
