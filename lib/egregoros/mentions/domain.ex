defmodule Egregoros.Mentions.Domain do
  @moduledoc false

  def normalize_host(nil), do: nil

  def normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
  end

  def normalize_host(_host), do: nil

  def local_domains(actor_ap_id) when is_binary(actor_ap_id) do
    case URI.parse(String.trim(actor_ap_id)) do
      %URI{host: host, port: port} when is_binary(host) and host != "" ->
        host = String.downcase(host)

        domains = [
          host,
          if(is_integer(port) and port > 0, do: host <> ":" <> Integer.to_string(port), else: nil)
        ]

        Enum.uniq(Enum.filter(domains, &is_binary/1))

      _ ->
        []
    end
  end

  def local_domains(_actor_ap_id), do: []
end
