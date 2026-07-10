defmodule EgregorosWeb.ClientIP do
  @moduledoc """
  Derives a client address without trusting attacker-supplied forwarding headers.

  X-Forwarded-For is considered only when the direct peer is covered by the
  configured trusted-proxy list. Entries may be exact IPv4/IPv6 addresses or
  CIDR ranges.
  """

  import Bitwise

  alias Egregoros.Config

  def address(%Plug.Conn{remote_ip: remote_ip} = conn) when is_tuple(remote_ip) do
    trusted = trusted_ranges()

    client_ip =
      if trusted?(remote_ip, trusted) do
        conn
        |> Plug.Conn.get_req_header("x-forwarded-for")
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&parse_ip/1)
        |> Enum.reject(&is_nil/1)
        |> Kernel.++([remote_ip])
        |> Enum.reverse()
        |> Enum.find(&(not trusted?(&1, trusted)))
        |> case do
          nil -> remote_ip
          ip -> ip
        end
      else
        remote_ip
      end

    format(client_ip)
  end

  def address(_conn), do: "unknown"

  defp trusted_ranges do
    Config.get(:trusted_proxies, [])
    |> List.wrap()
    |> Enum.map(&parse_range/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_range(value) when is_binary(value) do
    case String.split(String.trim(value), "/", parts: 2) do
      [address] ->
        with ip when not is_nil(ip) <- parse_ip(address) do
          {ip, address_bits(ip)}
        end

      [address, prefix] ->
        with ip when not is_nil(ip) <- parse_ip(address),
             {prefix, ""} <- Integer.parse(prefix),
             true <- prefix >= 0 and prefix <= address_bits(ip) do
          {ip, prefix}
        else
          _ -> nil
        end
    end
  end

  defp parse_range(_value), do: nil

  defp parse_ip(value) when is_binary(value) do
    value = String.trim(value)

    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> ip
      {:error, _reason} -> nil
    end
  end

  defp trusted?(ip, ranges) do
    Enum.any?(ranges, fn {network, prefix} -> same_prefix?(ip, network, prefix) end)
  end

  defp same_prefix?(ip, network, prefix) when tuple_size(ip) == tuple_size(network) do
    shift = address_bits(ip) - prefix
    ip_integer(ip) >>> shift == ip_integer(network) >>> shift
  end

  defp same_prefix?(_ip, _network, _prefix), do: false

  defp address_bits(ip) when tuple_size(ip) == 4, do: 32
  defp address_bits(ip) when tuple_size(ip) == 8, do: 128

  defp ip_integer(ip) when tuple_size(ip) == 4 do
    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> (acc <<< 8) + part end)
  end

  defp ip_integer(ip) when tuple_size(ip) == 8 do
    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> (acc <<< 16) + part end)
  end

  defp format(ip) do
    ip
    |> :inet.ntoa()
    |> List.to_string()
  end
end
