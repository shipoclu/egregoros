defmodule Egregoros.MiniApps.ExternalURL do
  @moduledoc false

  @max_url_bytes 2_048

  def validate(url) when is_binary(url) and byte_size(url) <= @max_url_bytes do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" ->
        {:ok, url}

      _ ->
        {:error, :invalid_url}
    end
  end

  def validate(_url), do: {:error, :invalid_url}
end
