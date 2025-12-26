defmodule Egregoros.DNS.Stub do
  @behaviour Egregoros.DNS

  @impl true
  def lookup_ips(_host) do
    {:ok, [{1, 1, 1, 1}]}
  end
end
