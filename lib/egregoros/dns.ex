defmodule Egregoros.DNS do
  @type ip_address :: :inet.ip_address()

  @callback lookup_ips(String.t()) :: {:ok, [ip_address()]} | {:error, term()}

  def lookup_ips(host) when is_binary(host) do
    impl().lookup_ips(host)
  end

  defp impl do
    Application.get_env(:egregoros, __MODULE__, Egregoros.DNS.Inet)
  end
end
