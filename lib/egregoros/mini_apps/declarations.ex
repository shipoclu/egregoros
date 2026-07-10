defmodule Egregoros.MiniApps.Declarations do
  @moduledoc false

  alias Egregoros.MiniApps
  alias Egregoros.MiniApps.Declaration
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.Repo

  def ensure(%Manifest{} = manifest) do
    with :ok <- require_origin_allowed(manifest.origin) do
      case Repo.transaction(fn -> ensure_locked(manifest) end) do
        {:ok, {%Declaration{} = declaration, status}} -> {:ok, declaration, status}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def ensure(_manifest), do: {:error, :invalid_manifest}

  def get_by_origin(origin) when is_binary(origin) do
    Repo.get_by(Declaration, app_origin: origin)
  end

  def get_by_origin(_origin), do: nil

  def wallet_enabled?(origin) when is_binary(origin) do
    case get_by_origin(origin) do
      %Declaration{wallet_evm_enabled: true} -> origin_allowed?(origin)
      _ -> false
    end
  end

  def wallet_enabled?(_origin), do: false

  defp ensure_locked(manifest) do
    lock_origin(manifest.origin)
    fingerprint = fingerprint(manifest)

    case get_by_origin(manifest.origin) do
      %Declaration{manifest_fingerprint: ^fingerprint} = declaration ->
        {declaration, :existing}

      %Declaration{} ->
        Repo.rollback(:manifest_changed)

      nil ->
        {create_declaration(manifest, fingerprint), :created}
    end
  end

  defp create_declaration(manifest, fingerprint) do
    oauth = manifest.oauth || %{redirect_uris: [], scopes: []}
    evm = get_in(manifest.wallet || %{}, [:evm]) || disabled_wallet()

    attrs = %{
      app_origin: manifest.origin,
      oauth_redirect_uris: oauth.redirect_uris,
      oauth_scopes: oauth.scopes,
      capabilities: manifest.capabilities,
      wallet_evm_enabled: evm.enabled,
      wallet_evm_required: evm.required,
      wallet_evm_required_chains: evm.required_chains,
      manifest_fingerprint: fingerprint,
      declared_at: DateTime.utc_now()
    }

    case %Declaration{} |> Declaration.changeset(attrs) |> Repo.insert() do
      {:ok, declaration} -> declaration
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp fingerprint(manifest) do
    oauth = manifest.oauth || %{redirect_uris: [], scopes: []}
    evm = get_in(manifest.wallet || %{}, [:evm]) || disabled_wallet()

    {oauth.redirect_uris, oauth.scopes, manifest.capabilities,
     {evm.enabled, evm.required, evm.required_chains}}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp disabled_wallet do
    %{enabled: false, required: false, required_chains: []}
  end

  defp lock_origin(origin) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtext($1))",
      ["mini-app-declaration:" <> origin]
    )
  end

  defp require_origin_allowed(origin) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) ->
        if MiniApps.domain_allowed?(host), do: :ok, else: {:error, :domain_denied}

      _ ->
        {:error, :invalid_origin}
    end
  end

  defp origin_allowed?(origin), do: require_origin_allowed(origin) == :ok
end
