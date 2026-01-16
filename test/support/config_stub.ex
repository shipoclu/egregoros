defmodule Egregoros.Config.Stub do
  @behaviour Egregoros.Config

  @impl true
  def get(key, default) when is_atom(key) do
    Application.get_env(:egregoros, key, default)
  end
end
