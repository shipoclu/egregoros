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

  def aliases_from_uri(%URI{} = uri) do
    host =
      case uri.host do
        value when is_binary(value) and value != "" -> String.downcase(value)
        _ -> nil
      end

    domain = from_uri(uri)

    [host, domain]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  def aliases_from_uri(_uri), do: []

  defp non_default_port?("http", port) when is_integer(port), do: port != 80
  defp non_default_port?("https", port) when is_integer(port), do: port != 443
  defp non_default_port?(_scheme, port) when is_integer(port), do: true
end
