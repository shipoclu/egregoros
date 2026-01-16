defmodule Egregoros.Config do
  @callback get(atom(), term()) :: term()

  def get(key, default \\ nil) when is_atom(key) do
    impl().get(key, default)
  end

  defp impl do
    Application.get_env(:egregoros, __MODULE__, Egregoros.Config.Application)
  end
end
