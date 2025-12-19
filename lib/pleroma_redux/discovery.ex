defmodule PleromaRedux.Discovery do
  @callback peers() :: [String.t()]

  def peers do
    impl().peers()
  end

  defp impl do
    Application.get_env(:pleroma_redux, __MODULE__, PleromaRedux.Discovery.DNS)
  end
end
