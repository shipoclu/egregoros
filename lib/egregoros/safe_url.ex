defmodule Egregoros.SafeURL do
  @moduledoc false

  import Bitwise

  @http_schemes ~w(http https)

  def validate_http_url(url) when is_binary(url) do
    uri = URI.parse(url)

    with scheme when scheme in @http_schemes <- uri.scheme,
         host when is_binary(host) and host != "" <- uri.host,
         :ok <- validate_host(host) do
      :ok
    else
      _ -> {:error, :unsafe_url}
    end
  end

  def validate_http_url(_), do: {:error, :unsafe_url}

  def validate_http_url_no_dns(url) when is_binary(url) do
    uri = URI.parse(url)

    with scheme when scheme in @http_schemes <- uri.scheme,
         host when is_binary(host) and host != "" <- uri.host,
         :ok <- validate_host_no_dns(host) do
      :ok
    else
      _ -> {:error, :unsafe_url}
    end
  end

  def validate_http_url_no_dns(_), do: {:error, :unsafe_url}

  defp validate_host("localhost"), do: {:error, :unsafe_url}

  defp validate_host(host) when is_binary(host) do
    if ip_literal?(host) do
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, ip} ->
          if private_ip?(ip), do: {:error, :unsafe_url}, else: :ok

        {:error, _} ->
          {:error, :unsafe_url}
      end
    else
      case Egregoros.DNS.lookup_ips(host) do
        {:ok, ips} when is_list(ips) and ips != [] ->
          if Enum.any?(ips, &private_ip?/1), do: {:error, :unsafe_url}, else: :ok

        _ ->
          {:error, :unsafe_url}
      end
    end
  end

  defp validate_host(_), do: {:error, :unsafe_url}

  defp validate_host_no_dns("localhost"), do: {:error, :unsafe_url}

  defp validate_host_no_dns(host) when is_binary(host) do
    host = String.trim(host)

    if String.downcase(host) == "localhost" do
      {:error, :unsafe_url}
    else
      case parse_ip_literal_no_dns(host) do
        {:ok, ip} ->
          if private_ip?(ip), do: {:error, :unsafe_url}, else: :ok

        :error ->
          if numeric_host_like?(host), do: {:error, :unsafe_url}, else: :ok
      end
    end
  end

  defp validate_host_no_dns(_), do: {:error, :unsafe_url}

  defp ip_literal?(host) when is_binary(host) do
    String.contains?(host, ":") or
      String.match?(host, ~r/^\d{1,3}(\.\d{1,3}){3}$/)
  end

  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, second, _, _}) when second in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({100, second, _, _}) when second in 64..127, do: true
  defp private_ip?({_, _, _, _}), do: false

  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_ip?({0, 0, 0, 0, 0, 65535, a, b}) when is_integer(a) and is_integer(b) do
    private_ip?(ipv4_from_v6_tail(a, b))
  end

  defp private_ip?({0, 0, 0, 0, 0, 0, a, b}) when is_integer(a) and is_integer(b) do
    private_ip?(ipv4_from_v6_tail(a, b))
  end

  defp private_ip?({first, _, _, _, _, _, _, _}) when (first &&& 0xFE00) == 0xFC00, do: true
  defp private_ip?({first, _, _, _, _, _, _, _}) when (first &&& 0xFFC0) == 0xFE80, do: true
  defp private_ip?({_, _, _, _, _, _, _, _}), do: false

  defp ipv4_from_v6_tail(a, b) when is_integer(a) and is_integer(b) do
    {
      a >>> 8 &&& 0xFF,
      a &&& 0xFF,
      b >>> 8 &&& 0xFF,
      b &&& 0xFF
    }
  end

  defp parse_ip_literal_no_dns(host) when is_binary(host) do
    host = String.trim(host)

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> parse_obfuscated_ipv4(host)
    end
  end

  defp parse_ip_literal_no_dns(_host), do: :error

  defp parse_obfuscated_ipv4(host) when is_binary(host) do
    host = String.trim(host)

    cond do
      host == "" ->
        :error

      String.contains?(host, ".") ->
        parse_ipv4_dotted(host)

      true ->
        parse_ipv4_integer(host)
    end
  end

  defp parse_obfuscated_ipv4(_host), do: :error

  defp parse_ipv4_integer("0x" <> hex), do: parse_ipv4_integer_hex(hex)
  defp parse_ipv4_integer("0X" <> hex), do: parse_ipv4_integer_hex(hex)

  defp parse_ipv4_integer(value) when is_binary(value) do
    with true <- String.match?(value, ~r/^\d+$/),
         {int, ""} <- Integer.parse(value, 10),
         true <- int >= 0 and int <= 0xFFFF_FFFF do
      {:ok, ipv4_from_int(int)}
    else
      _ -> :error
    end
  end

  defp parse_ipv4_integer(_value), do: :error

  defp parse_ipv4_integer_hex(hex) when is_binary(hex) do
    with true <- String.match?(hex, ~r/^[0-9a-fA-F]+$/),
         {int, ""} <- Integer.parse(hex, 16),
         true <- int >= 0 and int <= 0xFFFF_FFFF do
      {:ok, ipv4_from_int(int)}
    else
      _ -> :error
    end
  end

  defp parse_ipv4_integer_hex(_hex), do: :error

  defp parse_ipv4_dotted(host) when is_binary(host) do
    parts = String.split(host, ".", trim: false)

    with true <- length(parts) in 1..4,
         {:ok, ints} <- parse_ipv4_parts(parts),
         {:ok, ip} <- ipv4_from_parts(ints) do
      {:ok, ip}
    else
      _ -> :error
    end
  end

  defp parse_ipv4_dotted(_host), do: :error

  defp parse_ipv4_parts(parts) when is_list(parts) do
    ints =
      parts
      |> Enum.map(&parse_ipv4_part/1)

    if Enum.any?(ints, &(&1 == :error)) do
      :error
    else
      {:ok, ints}
    end
  end

  defp parse_ipv4_parts(_parts), do: :error

  defp parse_ipv4_part(part) when is_binary(part) do
    part = String.trim(part)

    cond do
      part == "" ->
        :error

      String.starts_with?(part, ["0x", "0X"]) ->
        parse_prefixed_int(part, 16, 2)

      String.match?(part, ~r/^\d+$/) ->
        {int, rest} = Integer.parse(part, 10)
        if rest == "" and int >= 0, do: int, else: :error

      true ->
        :error
    end
  end

  defp parse_ipv4_part(_part), do: :error

  defp parse_prefixed_int(part, base, prefix_len) when is_binary(part) do
    with digits when is_binary(digits) and digits != "" <- String.slice(part, prefix_len..-1//1),
         true <- String.match?(digits, ~r/^[0-9a-fA-F]+$/),
         {int, ""} <- Integer.parse(digits, base),
         true <- int >= 0 do
      int
    else
      _ -> :error
    end
  end

  defp ipv4_from_parts([a]) when is_integer(a) and a >= 0 and a <= 0xFFFF_FFFF do
    {:ok, ipv4_from_int(a)}
  end

  defp ipv4_from_parts([a, b])
       when is_integer(a) and is_integer(b) and a in 0..255 and b >= 0 and b <= 0xFF_FFFF do
    {:ok, ipv4_from_int(a <<< 24 ||| b)}
  end

  defp ipv4_from_parts([a, b, c])
       when is_integer(a) and is_integer(b) and is_integer(c) and a in 0..255 and b in 0..255 and
              c >= 0 and c <= 0xFFFF do
    {:ok, ipv4_from_int(a <<< 24 ||| b <<< 16 ||| c)}
  end

  defp ipv4_from_parts([a, b, c, d])
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) and
              a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    {:ok, {a, b, c, d}}
  end

  defp ipv4_from_parts(_parts), do: :error

  defp ipv4_from_int(int) when is_integer(int) do
    {
      int >>> 24 &&& 0xFF,
      int >>> 16 &&& 0xFF,
      int >>> 8 &&& 0xFF,
      int &&& 0xFF
    }
  end

  defp numeric_host_like?(host) when is_binary(host) do
    host = String.trim(host)

    cond do
      host == "" ->
        false

      String.starts_with?(host, ["0x", "0X"]) ->
        true

      String.match?(host, ~r/^\d+$/) ->
        true

      String.contains?(host, ".") ->
        parts = String.split(host, ".", trim: false)
        length(parts) in 1..4 and Enum.all?(parts, &numeric_host_part?/1)

      true ->
        false
    end
  end

  defp numeric_host_like?(_host), do: false

  defp numeric_host_part?(part) when is_binary(part) do
    part = String.trim(part)

    cond do
      part == "" ->
        false

      String.starts_with?(part, ["0x", "0X"]) ->
        String.match?(String.slice(part, 2..-1//1), ~r/^[0-9a-fA-F]+$/)

      true ->
        String.match?(part, ~r/^\d+$/)
    end
  end

  defp numeric_host_part?(_part), do: false
end
