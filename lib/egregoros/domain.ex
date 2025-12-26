defmodule Egregoros.Domain do
  @moduledoc false

  def from_uri(%URI{host: host} = uri) when is_binary(host) and host != "" do
    host = String.downcase(host)
    port = uri.port
    scheme = uri.scheme

    if is_integer(port) and port > 0 and non_default_port?(scheme, port) do
      host <> ":" <> Integer.to_string(port)
    else
      host
    end
  end

  def from_uri(_uri), do: nil

  defp non_default_port?("http", port) when is_integer(port), do: port != 80
  defp non_default_port?("https", port) when is_integer(port), do: port != 443
  defp non_default_port?(_scheme, port) when is_integer(port), do: true
end
