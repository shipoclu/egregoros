defmodule Egregoros.Discovery do
  @callback peers() :: [String.t()]

  def peers do
    impl().peers()
  end

  defp impl do
    Application.get_env(:egregoros, __MODULE__, Egregoros.Discovery.DNS)
  end
end
