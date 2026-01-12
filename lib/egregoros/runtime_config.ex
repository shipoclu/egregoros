defmodule Egregoros.RuntimeConfig do
  @moduledoc """
  Runtime configuration access with a process-local override mechanism.

  Production code should treat configuration as globally defined via `Application` env.
  Tests can use `with/2` to override specific keys without mutating global config, which
  keeps tests async-safe and avoids brittle `Application.put_env/3` patterns.
  """

  @app :egregoros
  @overrides_key {__MODULE__, :overrides}

  def get(key, default \\ nil) when is_atom(key) do
    overrides = Process.get(@overrides_key, %{})

    if is_map(overrides) and Map.has_key?(overrides, key) do
      Map.fetch!(overrides, key)
    else
      Application.get_env(@app, key, default)
    end
  end

  def with(overrides, fun) when is_map(overrides) and is_function(fun, 0) do
    old = Process.get(@overrides_key, %{})
    Process.put(@overrides_key, Map.merge(old, overrides))

    try do
      fun.()
    after
      Process.put(@overrides_key, old)
    end
  end
end

