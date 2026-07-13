defmodule Egregoros.MiniApps.Declarations do
  @moduledoc false

  import Ecto.Query, only: [where: 3]

  alias Egregoros.MiniApps
  alias Egregoros.MiniApps.Declaration
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.Repo
  alias Egregoros.Workers.ActivateMiniAppActor

  def ensure(%Manifest{} = manifest) do
    with :ok <- require_origin_allowed(manifest.origin) do
      case Repo.transaction(fn -> ensure_locked(manifest) end) do
        {:ok, {%Declaration{} = declaration, status}} ->
          _ = ActivateMiniAppActor.maybe_enqueue(declaration)
          {:ok, declaration, status}

        {:error, reason} ->
          {:error, reason}
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

  def notification_actor(origin) when is_binary(origin) do
    case get_by_origin(origin) do
      %Declaration{
        activity_pub_actor_url: actor_url,
        activity_pub_transactional_mentions: true,
        activity_pub_actor_fingerprint: fingerprint,
        activity_pub_actor_key_id: key_id,
        activity_pub_actor_key_fingerprint: key_fingerprint,
        activity_pub_actor_public_key_pem: public_key_pem,
        activity_pub_actor_activated_at: %DateTime{}
      }
      when is_binary(actor_url) and is_binary(fingerprint) and is_binary(key_id) and
             is_binary(key_fingerprint) and is_binary(public_key_pem) ->
        if origin_allowed?(origin),
          do: {:ok, actor_url},
          else: {:error, :notifications_not_declared}

      %Declaration{
        activity_pub_actor_url: actor_url,
        activity_pub_transactional_mentions: true
      }
      when is_binary(actor_url) ->
        {:error, :actor_not_activated}

      _ ->
        {:error, :notifications_not_declared}
    end
  end

  def notification_actor(_origin), do: {:error, :notifications_not_declared}

  def notification_origin_for_actor(actor_url) when is_binary(actor_url) do
    case activity_pub_declaration_for_actor(actor_url) do
      {:ok, %Declaration{app_origin: origin, activity_pub_transactional_mentions: true}} ->
        {:ok, origin}

      {:ok, %Declaration{}} ->
        {:error, :notifications_not_declared}

      result ->
        result
    end
  end

  def notification_origin_for_actor(_actor_url), do: :not_declared

  def activity_pub_declaration_for_actor(actor_url) when is_binary(actor_url) do
    declarations =
      Declaration
      |> where(
        [declaration],
        declaration.activity_pub_actor_url == ^actor_url
      )
      |> Repo.all()

    case declarations do
      [%Declaration{app_origin: origin} = declaration] ->
        cond do
          not origin_allowed?(origin) -> {:error, :domain_denied}
          actor_activated?(declaration) -> {:ok, declaration}
          true -> {:error, :actor_not_activated}
        end

      [] ->
        :not_declared

      _ ->
        {:error, :ambiguous_actor}
    end
  end

  def activity_pub_declaration_for_actor(_actor_url), do: :not_declared

  defp ensure_locked(manifest) do
    lock_origin(manifest.origin)
    fingerprint = fingerprint(manifest)

    case get_by_origin(manifest.origin) do
      %Declaration{manifest_fingerprint: ^fingerprint} = declaration ->
        {declaration, :existing}

      %Declaration{} = declaration ->
        if legacy_fingerprint_compatible?(declaration, manifest) do
          declaration
          |> Ecto.Changeset.change(
            manifest_fingerprint: fingerprint,
            oauth_scope_authorization_max_age_seconds: %{}
          )
          |> Repo.update!()
          |> then(&{&1, :existing})
        else
          Repo.rollback(:manifest_changed)
        end

      nil ->
        {create_declaration(manifest, fingerprint), :created}
    end
  end

  defp create_declaration(manifest, fingerprint) do
    oauth =
      manifest.oauth ||
        %{redirect_uris: [], scopes: [], scope_authorization_max_age_seconds: %{}}

    evm = get_in(manifest.wallet || %{}, [:evm]) || disabled_wallet()
    activity_pub = manifest.activity_pub || disabled_activity_pub()

    attrs = %{
      app_origin: manifest.origin,
      oauth_redirect_uris: oauth.redirect_uris,
      oauth_scopes: oauth.scopes,
      oauth_scope_authorization_max_age_seconds:
        Map.get(oauth, :scope_authorization_max_age_seconds, %{}),
      capabilities: manifest.capabilities,
      wallet_evm_enabled: evm.enabled,
      wallet_evm_required: evm.required,
      wallet_evm_required_chains: evm.required_chains,
      activity_pub_actor_url: activity_pub.actor_url,
      activity_pub_public_notes: activity_pub.public_notes,
      activity_pub_transactional_mentions: activity_pub.transactional_mentions,
      manifest_fingerprint: fingerprint,
      declared_at: DateTime.utc_now()
    }

    case %Declaration{} |> Declaration.changeset(attrs) |> Repo.insert() do
      {:ok, declaration} -> declaration
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp fingerprint(manifest) do
    oauth =
      manifest.oauth ||
        %{redirect_uris: [], scopes: [], scope_authorization_max_age_seconds: %{}}

    evm = get_in(manifest.wallet || %{}, [:evm]) || disabled_wallet()
    activity_pub = manifest.activity_pub || disabled_activity_pub()

    {oauth.redirect_uris, oauth.scopes, Map.get(oauth, :scope_authorization_max_age_seconds, %{}),
     manifest.capabilities, {evm.enabled, evm.required, evm.required_chains},
     {activity_pub.actor_url, activity_pub.public_notes, activity_pub.transactional_mentions}}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp legacy_fingerprint_compatible?(declaration, manifest) do
    oauth = manifest.oauth || %{redirect_uris: [], scopes: []}

    if Map.get(oauth, :scope_authorization_max_age_seconds, %{}) == %{} do
      evm = get_in(manifest.wallet || %{}, [:evm]) || disabled_wallet()
      activity_pub = manifest.activity_pub || disabled_activity_pub()

      legacy =
        {oauth.redirect_uris, oauth.scopes, manifest.capabilities,
         {evm.enabled, evm.required, evm.required_chains},
         {activity_pub.actor_url, activity_pub.public_notes, activity_pub.transactional_mentions}}
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))

      declaration.manifest_fingerprint == legacy
    else
      false
    end
  end

  defp disabled_wallet do
    %{enabled: false, required: false, required_chains: []}
  end

  defp disabled_activity_pub do
    %{actor_url: nil, public_notes: false, transactional_mentions: false}
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

  defp actor_activated?(%Declaration{
         activity_pub_actor_fingerprint: fingerprint,
         activity_pub_actor_key_id: key_id,
         activity_pub_actor_key_fingerprint: key_fingerprint,
         activity_pub_actor_public_key_pem: public_key_pem,
         activity_pub_actor_activated_at: %DateTime{}
       })
       when is_binary(fingerprint) and is_binary(key_id) and is_binary(key_fingerprint) and
              is_binary(public_key_pem),
       do: true

  defp actor_activated?(%Declaration{}), do: false
end
