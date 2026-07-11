defmodule Egregoros.MiniApps.Fetcher.BoundedHTTPError do
  @moduledoc false

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}), do: "bounded HTTP fetch failed: #{inspect(reason)}"
end
