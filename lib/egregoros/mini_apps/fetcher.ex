defmodule Egregoros.MiniApps.Fetcher do
  @moduledoc """
  Behaviour boundary for fetching untrusted mini-app resources.

  Callers receive raw bytes only. Implementations must enforce HTTPS, public DNS
  pinning, redirect refusal, MIME checks, and resource-specific response limits.
  """

  @type kind :: :manifest | :page | :asset
  @type response :: %{status: 200, body: binary(), headers: [{binary(), binary()}]}

  @callback get(String.t(), kind()) :: {:ok, response()} | {:error, term()}

  def get(url, kind) when is_binary(url) and kind in [:manifest, :page, :asset] do
    impl().get(url, kind)
  end

  def get(_url, _kind), do: {:error, :unsupported_resource_kind}

  defp impl do
    Egregoros.Config.get(__MODULE__, Egregoros.MiniApps.Fetcher.Req)
  end
end
