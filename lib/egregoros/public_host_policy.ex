defmodule Egregoros.PublicHostPolicy do
  @moduledoc """
  Canonical public hostnames that may receive Egregoros's host-only session cookie.

  Cookies are scoped to hostnames, not ports. Security decisions must therefore
  compare normalized hostnames and deliberately ignore the URL port.
  """

  alias Egregoros.Config
  alias Egregoros.MiniApps.DomainPolicy
  alias EgregorosWeb.Endpoint

  def cookie_host?(candidate, request_host \\ nil)

  def cookie_host?(candidate, request_host) when is_binary(candidate) do
    with {:ok, candidate} <- normalize_host(candidate) do
      candidate in public_hosts(request_host)
    else
      _ -> false
    end
  end

  def cookie_host?(_candidate, _request_host), do: false

  def public_host?(candidate) when is_binary(candidate), do: cookie_host?(candidate)
  def public_host?(_candidate), do: false

  def public_hosts(request_host \\ nil) do
    endpoint_host = Endpoint.url() |> URI.parse() |> Map.get(:host)
    aliases = Config.get(:public_host_aliases, [])

    [endpoint_host, request_host | List.wrap(aliases)]
    |> Enum.flat_map(fn host ->
      case normalize_host(host) do
        {:ok, normalized} -> [normalized]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  def normalize_host(value) when is_binary(value) do
    value = String.trim(value)

    candidate = if String.contains?(value, "://"), do: value, else: "https://" <> value

    with true <- value != "",
         {:ok, %URI{} = uri} <- URI.new(candidate),
         true <- uri.scheme == "https",
         true <- uri.userinfo in [nil, ""],
         true <- uri.path in [nil, ""],
         true <- uri.query in [nil, ""],
         true <- uri.fragment in [nil, ""],
         host when is_binary(host) <- uri.host do
      DomainPolicy.normalize_domain(host)
    else
      _ -> {:error, :invalid_domain}
    end
  end

  def normalize_host(_value), do: {:error, :invalid_domain}
end
