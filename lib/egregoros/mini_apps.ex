defmodule Egregoros.MiniApps do
  @moduledoc """
  Security-gated entry points for Fediverse mini apps.

  The feature is disabled unless explicitly enabled. Domain policy is evaluated
  centrally so future discovery, iframe, OAuth, compose, and wallet entry points
  can share the same decision.
  """

  alias Egregoros.Config
  alias Egregoros.MiniApps.DomainPolicy
  alias Egregoros.MiniApps.CardMetadata
  alias Egregoros.MiniApps.Discovery
  alias Egregoros.MiniApps.Fetcher
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.Origin
  alias Egregoros.MiniApps.PageMetadata
  alias Egregoros.MiniApps.ResolvedCard

  @manifest_path "/.well-known/fediverse-miniapp.json"

  def enabled? do
    truthy?(Config.get(:mini_apps_enabled, false))
  end

  def domain_allowed?(domain) when is_binary(domain) do
    enabled?() and
      DomainPolicy.allowed?(domain,
        allow: Config.get(:mini_apps_domain_allowlist, []),
        deny: Config.get(:mini_apps_domain_denylist, [])
      )
  end

  def domain_allowed?(_domain), do: false

  def fetch_manifest(origin) when is_binary(origin) do
    with :ok <- require_enabled(),
         {:ok, origin} <- Origin.parse_origin(origin),
         %URI{host: domain} when is_binary(domain) <- URI.parse(origin),
         :ok <- require_domain_allowed(domain),
         manifest_url = origin <> @manifest_path,
         {:ok, %{body: body}} <- Fetcher.get(manifest_url, :manifest),
         {:ok, manifest} <- Manifest.decode(body, manifest_url) do
      {:ok, manifest}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_origin}
    end
  end

  def fetch_manifest(_origin), do: {:error, :invalid_origin}

  def resolve_note(object) do
    with :ok <- require_enabled() do
      object
      |> Discovery.candidate_urls()
      |> Enum.reduce_while({:error, :no_mini_app}, fn url, _acc ->
        case resolve_candidate(url) do
          {:ok, %ResolvedCard{} = card} -> {:halt, {:ok, card}}
          {:error, _reason} -> {:cont, {:error, :no_mini_app}}
        end
      end)
    end
  end

  defp resolve_candidate(url) do
    with {:ok, origin} <- Origin.from_url(url),
         {:ok, manifest} <- fetch_manifest(origin),
         :ok <- require_origin_allowed(origin),
         {:ok, %{body: html}} <- Fetcher.get(url, :page) do
      {:ok, build_resolved_card(url, manifest, html)}
    end
  end

  defp build_resolved_card(source_url, manifest, html) do
    case page_card(html, source_url, manifest.origin) do
      {:ok, card} ->
        %ResolvedCard{
          source_url: source_url,
          app_origin: manifest.origin,
          app_name: manifest.name,
          title: card.title,
          button_title: card.button_title,
          launch_url: card.launch_url,
          image_url: card.image_url,
          manifest: manifest
        }

      :generic ->
        %ResolvedCard{
          source_url: source_url,
          app_origin: manifest.origin,
          app_name: manifest.name,
          title: manifest.name,
          button_title: "Open",
          launch_url: source_url,
          image_url: manifest.icon_url,
          manifest: manifest
        }
    end
  end

  defp page_card(html, source_url, origin) do
    with {:ok, json} when is_binary(json) <- PageMetadata.extract(html),
         {:ok, %CardMetadata{} = card} <- CardMetadata.decode(json, source_url, origin) do
      {:ok, card}
    else
      _ -> :generic
    end
  end

  defp require_enabled do
    if enabled?(), do: :ok, else: {:error, :disabled}
  end

  defp require_domain_allowed(domain) do
    if domain_allowed?(domain), do: :ok, else: {:error, :domain_denied}
  end

  defp require_origin_allowed(origin) do
    case URI.parse(origin) do
      %URI{host: domain} when is_binary(domain) -> require_domain_allowed(domain)
      _ -> {:error, :invalid_origin}
    end
  end

  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_value), do: false
end
