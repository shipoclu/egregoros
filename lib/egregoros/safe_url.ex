defmodule Egregoros.SafeURL do
  @moduledoc false

  import Bitwise

  alias Egregoros.Config
  alias Egregoros.MiniApps.DomainPolicy

  @http_schemes ~w(http https)

  def validate_http_url(url) when is_binary(url) do
    case resolve_http_url(url) do
      {:ok, _resolved} -> :ok
      {:error, _} = error -> error
    end
  end

  def validate_http_url(_), do: {:error, :unsafe_url}

  def resolve_https_domain_url(url) when is_binary(url) do
    with {:ok, %URI{} = uri} <- parse_http_uri(url),
         "https" <- uri.scheme,
         host when is_binary(host) and host != "" <- uri.host,
         true <- is_nil(uri.userinfo),
         true <- uri.fragment in [nil, ""],
         {:ok, host} <- DomainPolicy.normalize_domain(host),
         {:ok, ip} <- resolve_public_ip(host) do
      normalized_uri = %URI{uri | host: host, fragment: nil}
      port = normalized_uri.port || 443

      {:ok,
       %{
         authority: authority(host, port, 443),
         canonical_url: URI.to_string(normalized_uri),
         connect_url: connect_url(normalized_uri, ip),
         hostname: host,
         ip: ip,
         port: port
       }}
    else
      _ -> {:error, :unsafe_url}
    end
  end

  def resolve_https_domain_url(_url), do: {:error, :unsafe_url}

  def resolve_http_url_federation(url) when is_binary(url) do
    if allow_private_federation?() do
      with {:ok, %URI{host: host}} <- validate_http_url_shape(url) do
        {:ok, %{connect_url: url, hostname: host, ip: nil}}
      else
        _ -> {:error, :unsafe_url}
      end
    else
      resolve_http_url(url)
    end
  end

  def resolve_http_url_federation(_url), do: {:error, :unsafe_url}

  defp resolve_http_url(url) when is_binary(url) do
    with {:ok, %URI{} = uri} <- parse_http_uri(url),
         scheme when scheme in @http_schemes <- uri.scheme,
         host when is_binary(host) and host != "" <- uri.host,
         true <- is_nil(uri.userinfo),
         {:ok, ip} <- resolve_public_ip(host) do
      {:ok,
       %{
         connect_url: connect_url(uri, ip),
         hostname: host,
         ip: ip
       }}
    else
      _ -> {:error, :unsafe_url}
    end
  end

  defp resolve_http_url(_url), do: {:error, :unsafe_url}

  defp validate_http_url_shape(url) do
    case parse_http_uri(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: userinfo} = uri}
      when scheme in @http_schemes and is_binary(host) and host != "" and
             is_nil(userinfo) ->
        {:ok, uri}

      _ ->
        {:error, :unsafe_url}
    end
  end

  def validate_http_url_federation(url) when is_binary(url) do
    if allow_private_federation?() do
      validate_http_url_no_dns(url)
    else
      validate_http_url(url)
    end
  end

  def validate_http_url_federation(_), do: {:error, :unsafe_url}

  def validate_http_url_no_dns(url) when is_binary(url) do
    with {:ok, %URI{} = uri} <- parse_http_uri(url),
         scheme when scheme in @http_schemes <- uri.scheme,
         host when is_binary(host) and host != "" <- uri.host,
         true <- is_nil(uri.userinfo),
         :ok <- validate_host_no_dns(host) do
      :ok
    else
      _ -> {:error, :unsafe_url}
    end
  end

  def validate_http_url_no_dns(_), do: {:error, :unsafe_url}

  defp allow_private_federation? do
    case Config.get(:allow_private_federation, false) do
      true -> true
      "true" -> true
      1 -> true
      "1" -> true
      _ -> false
    end
  end

  defp resolve_public_ip("localhost"), do: {:error, :unsafe_url}

  defp resolve_public_ip(host) when is_binary(host) do
    with {:ok, ips} <- resolve_ips(host),
         true <- ips != [] and Enum.all?(ips, &globally_routable?/1) do
      {:ok, List.first(ips)}
    else
      _ -> {:error, :unsafe_url}
    end
  end

  defp resolve_public_ip(_host), do: {:error, :unsafe_url}

  defp resolve_ips(host) do
    if ip_literal?(host) or numeric_host_like?(host) do
      case parse_ip_literal_no_dns(host) do
        {:ok, ip} -> {:ok, [ip]}
        :error -> {:error, :unsafe_url}
      end
    else
      Egregoros.DNS.lookup_ips(host)
    end
  end

  defp validate_host_no_dns("localhost"), do: {:error, :unsafe_url}

  defp validate_host_no_dns(host) when is_binary(host) do
    host = String.trim(host)

    if String.downcase(host) == "localhost" do
      {:error, :unsafe_url}
    else
      case parse_ip_literal_no_dns(host) do
        {:ok, ip} ->
          if globally_routable?(ip), do: :ok, else: {:error, :unsafe_url}

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

  defp globally_routable?({first, _, _, _}) when first in [0, 10, 127], do: false
  defp globally_routable?({100, second, _, _}) when second in 64..127, do: false
  defp globally_routable?({169, 254, _, _}), do: false
  defp globally_routable?({172, second, _, _}) when second in 16..31, do: false
  defp globally_routable?({192, 0, 0, _}), do: false
  defp globally_routable?({192, 0, 2, _}), do: false
  # Deprecated 6to4 relay anycast. IANA marks the full prefix non-global.
  defp globally_routable?({192, 88, 99, _}), do: false
  defp globally_routable?({192, 168, _, _}), do: false
  defp globally_routable?({198, second, _, _}) when second in 18..19, do: false
  defp globally_routable?({198, 51, 100, _}), do: false
  defp globally_routable?({203, 0, 113, _}), do: false
  defp globally_routable?({first, _, _, _}) when first >= 224, do: false
  defp globally_routable?({_, _, _, _}), do: true

  defp globally_routable?({0, 0, 0, 0, 0, 65535, _, _}), do: false
  defp globally_routable?({0, 0, 0, 0, 0, 0, _, _}), do: false
  # IETF protocol assignments, benchmarking, and ORCHID are not ordinary
  # globally reachable application destinations.
  defp globally_routable?({0x2001, second, _, _, _, _, _, _}) when second in 0x0000..0x002F,
    do: false

  defp globally_routable?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: false
  # 6to4 embeds an IPv4 destination and can bypass the IPv4 policy through a
  # locally configured transition relay.
  defp globally_routable?({0x2002, _, _, _, _, _, _, _}), do: false
  # IANA currently reserves 3f00::/8, including retired 6bone space and the
  # RFC 9637 documentation prefix.
  defp globally_routable?({first, _, _, _, _, _, _, _}) when first in 0x3F00..0x3FFF,
    do: false

  defp globally_routable?({first, _, _, _, _, _, _, _})
       when (first &&& 0xE000) == 0x2000,
       do: true

  defp globally_routable?({_, _, _, _, _, _, _, _}), do: false

  defp connect_url(%URI{} = uri, ip) do
    host = ip |> :inet.ntoa() |> List.to_string()
    uri |> Map.put(:host, host) |> Map.put(:userinfo, nil) |> URI.to_string()
  end

  defp authority(host, port, default_port) when port == default_port, do: host
  defp authority(host, port, _default_port), do: "#{host}:#{port}"

  defp parse_http_uri(url) when is_binary(url) do
    with true <- String.valid?(url),
         false <- forbidden_raw_byte?(url),
         true <- valid_percent_encoding?(url),
         {:ok, %URI{} = uri} <- URI.new(url) do
      {:ok, uri}
    else
      _ -> {:error, :unsafe_url}
    end
  end

  defp parse_http_uri(_url), do: {:error, :unsafe_url}

  defp forbidden_raw_byte?(url) do
    url
    |> :binary.bin_to_list()
    |> Enum.any?(fn byte -> byte <= 0x20 or byte in [0x5C, 0x7F] end)
  end

  defp valid_percent_encoding?(<<>>), do: true

  defp valid_percent_encoding?(<<?%, high, low, rest::binary>>) do
    with {:ok, high} <- hex_value(high),
         {:ok, low} <- hex_value(low),
         byte = high * 16 + low,
         false <- byte <= 0x1F or byte in [0x5C, 0x7F] do
      valid_percent_encoding?(rest)
    else
      _ -> false
    end
  end

  defp valid_percent_encoding?(<<?%, _rest::binary>>), do: false
  defp valid_percent_encoding?(<<_byte, rest::binary>>), do: valid_percent_encoding?(rest)

  defp hex_value(byte) when byte in ?0..?9, do: {:ok, byte - ?0}
  defp hex_value(byte) when byte in ?a..?f, do: {:ok, byte - ?a + 10}
  defp hex_value(byte) when byte in ?A..?F, do: {:ok, byte - ?A + 10}
  defp hex_value(_byte), do: :error

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

  defp parse_ipv4_integer("0" <> rest = value) when rest != "" do
    case parse_octal_int(value) do
      int when is_integer(int) and int <= 0xFFFF_FFFF -> {:ok, ipv4_from_int(int)}
      _ -> :error
    end
  end

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

      byte_size(part) > 1 and String.starts_with?(part, "0") ->
        parse_octal_int(part)

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

  defp parse_octal_int(part) when is_binary(part) do
    with digits when is_binary(digits) and digits != "" <- String.slice(part, 1..-1//1),
         true <- String.match?(digits, ~r/^[0-7]+$/),
         {int, ""} <- Integer.parse(digits, 8),
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
