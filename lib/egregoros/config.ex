defmodule Egregoros.Config do
  @callback get(atom(), term()) :: term()

  @impl_key {__MODULE__, :impl}

  def get(key, default \\ nil) when is_atom(key) do
    impl().get(key, default)
  end

  @doc false
  def put_impl(impl) when is_atom(impl) do
    Process.put(@impl_key, impl)
  end

  @doc false
  def clear_impl do
    Process.delete(@impl_key)
  end

  @doc false
  def with_impl(impl, fun) when is_atom(impl) and is_function(fun, 0) do
    previous = Process.get(@impl_key)
    Process.put(@impl_key, impl)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(@impl_key), else: Process.put(@impl_key, previous)
    end
  end

  defp impl do
    Process.get(@impl_key) ||
      Application.get_env(:egregoros, __MODULE__, Egregoros.Config.Application)
  end
end
