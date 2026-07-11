defmodule Egregoros.MiniApps.ExternalURL do
  @moduledoc false

  alias Egregoros.MiniApps.DomainPolicy

  @max_url_bytes 2_048

  def validate(url) when is_binary(url) and byte_size(url) <= @max_url_bytes do
    with true <- safe_url_bytes?(url),
         {:ok, %URI{scheme: "https", host: host, userinfo: userinfo, port: port}} <- URI.new(url),
         true <- is_nil(userinfo),
         {:ok, _host} <- DomainPolicy.normalize_domain(host),
         true <- valid_port?(port) do
      {:ok, url}
    else
      _ -> {:error, :invalid_url}
    end
  end

  def validate(_url), do: {:error, :invalid_url}

  defp safe_url_bytes?(url) do
    String.valid?(url) and
      not Enum.any?(:binary.bin_to_list(url), &(&1 <= 0x20 or &1 in [0x5C, 0x7F])) and
      valid_percent_encoding?(url)
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

  defp valid_port?(port) when is_integer(port), do: port in 1..65_535
  defp valid_port?(_port), do: false
end
