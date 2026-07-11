defmodule Egregoros.MiniApps.Origin do
  @moduledoc false

  alias Egregoros.MiniApps.DomainPolicy

  @manifest_path "/.well-known/fediverse-miniapp.json"
  @max_url_bytes 2_048

  def from_manifest_url(url) when is_binary(url) do
    with {:ok, uri, origin} <- parse_url(url),
         true <- uri.path == @manifest_path,
         true <- uri.query in [nil, ""],
         true <- uri.fragment in [nil, ""] do
      {:ok, origin}
    else
      _ -> {:error, :invalid_manifest_url}
    end
  end

  def from_manifest_url(_url), do: {:error, :invalid_manifest_url}

  def from_url(url) when is_binary(url) do
    with {:ok, _uri, origin} <- parse_url(url) do
      {:ok, origin}
    end
  end

  def from_url(_url), do: {:error, :invalid_url}

  def normalize_url(url) when is_binary(url) do
    with {:ok, uri, origin} <- parse_url(url) do
      {:ok, URI.to_string(uri), origin}
    end
  end

  def normalize_url(_url), do: {:error, :invalid_url}

  def parse_origin(origin) when is_binary(origin) do
    with {:ok, uri, normalized} <- parse_url(origin),
         true <- uri.path in [nil, ""],
         true <- uri.query in [nil, ""],
         true <- uri.fragment in [nil, ""] do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_origin}
    end
  end

  def parse_origin(_origin), do: {:error, :invalid_origin}

  def validate_url(url, expected_origin) when is_binary(url) and is_binary(expected_origin) do
    with {:ok, _uri, actual_origin} <- parse_url(url),
         {:ok, expected_origin} <- parse_origin(expected_origin),
         true <- actual_origin == expected_origin do
      :ok
    else
      false -> {:error, :origin_mismatch}
      {:error, :invalid_origin} -> {:error, :invalid_origin}
      _ -> {:error, :invalid_url}
    end
  end

  def validate_url(_url, _expected_origin), do: {:error, :invalid_url}

  defp parse_url(url) when byte_size(url) <= @max_url_bytes do
    with true <- safe_url_bytes?(url),
         {:ok, %URI{} = uri} <- URI.new(url),
         scheme when is_binary(scheme) <- uri.scheme,
         "https" <- String.downcase(scheme),
         true <- is_nil(uri.userinfo),
         true <- uri.fragment in [nil, ""],
         host when is_binary(host) <- uri.host,
         {:ok, host} <- DomainPolicy.normalize_domain(host),
         true <- valid_port?(uri.port),
         true <- valid_path?(uri.path) do
      port = uri.port || 443
      origin = if port == 443, do: "https://" <> host, else: "https://#{host}:#{port}"

      {:ok, %URI{uri | scheme: "https", host: host, fragment: nil}, origin}
    else
      _ -> {:error, :invalid_url}
    end
  end

  defp parse_url(_url), do: {:error, :invalid_url}

  defp valid_port?(nil), do: true
  defp valid_port?(port) when is_integer(port), do: port in 1..65_535
  defp valid_port?(_port), do: false

  defp valid_path?(nil), do: true
  defp valid_path?("/" <> _rest), do: true
  defp valid_path?(_path), do: false

  defp safe_url_bytes?(url) do
    String.valid?(url) and not forbidden_raw_byte?(url) and valid_percent_encoding?(url)
  end

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
end
