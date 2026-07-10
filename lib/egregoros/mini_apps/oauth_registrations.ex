defmodule Egregoros.MiniApps.OAuthRegistrations do
  @moduledoc false

  import Ecto.Query

  alias Egregoros.MiniApps
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.OAuthRegistration
  alias Egregoros.OAuth
  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.OAuth.Scopes
  alias Egregoros.OAuth.Token
  alias Egregoros.Repo

  def register(%Manifest{oauth: nil}), do: {:error, :oauth_not_declared}

  def register(%Manifest{oauth: oauth} = manifest) when is_map(oauth) do
    case register_with_status(manifest) do
      {:ok, registration, _status} -> {:ok, registration}
      {:error, reason} -> {:error, reason}
    end
  end

  def register(_manifest), do: {:error, :invalid_manifest}

  def register_with_status(%Manifest{oauth: nil}), do: {:error, :oauth_not_declared}

  def register_with_status(%Manifest{oauth: oauth} = manifest) when is_map(oauth) do
    with :ok <- require_origin_allowed(manifest.origin) do
      case Repo.transaction(fn -> register_locked(manifest) end) do
        {:ok, {%OAuthRegistration{} = registration, status}} ->
          {:ok, registration, status}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def register_with_status(_manifest), do: {:error, :invalid_manifest}

  def get_by_origin(origin) when is_binary(origin) do
    Repo.get_by(OAuthRegistration, app_origin: origin)
  end

  def get_by_application_id(application_id) when is_binary(application_id) do
    Repo.get_by(OAuthRegistration, oauth_application_id: application_id)
  end

  def application_allowed?(%OAuthApplication{} = application) do
    case get_by_application_id(application.id) do
      nil ->
        true

      %OAuthRegistration{} = registration ->
        origin_allowed?(registration.app_origin) and
          registration.redirect_uris == application.redirect_uris and
          exact_scopes?(application.scopes, registration.scopes)
    end
  end

  def application_allowed?(_application), do: false

  def capability_allowed?(origin, capability)
      when is_binary(origin) and is_binary(capability) do
    with %OAuthRegistration{} = registration <- get_by_origin(origin),
         true <- capability in registration.capabilities,
         %OAuthApplication{} = application <-
           Repo.get(OAuthApplication, registration.oauth_application_id) do
      application_allowed?(application)
    else
      _ -> false
    end
  end

  def capability_allowed?(_origin, _capability), do: false

  def active_user_grant?(origin, user_id) when is_binary(origin) and is_binary(user_id) do
    with %OAuthRegistration{} = registration <- get_by_origin(origin),
         %OAuthApplication{} = application <-
           Repo.get(OAuthApplication, registration.oauth_application_id),
         true <- application_allowed?(application) do
      now = DateTime.utc_now()

      from(token in Token,
        where:
          token.application_id == ^application.id and token.user_id == ^user_id and
            is_nil(token.revoked_at) and
            (is_nil(token.expires_at) or token.expires_at > ^now),
        select: token.scopes
      )
      |> Repo.all()
      |> Enum.any?(&exact_scopes?(&1, registration.scopes))
    else
      _ -> false
    end
  end

  def active_user_grant?(_origin, _user_id), do: false

  def validate_authorization(%OAuthApplication{} = application, redirect_uri, scopes, opts)
      when is_binary(redirect_uri) and is_binary(scopes) and is_list(opts) do
    case get_by_application_id(application.id) do
      nil ->
        :ok

      %OAuthRegistration{} = registration ->
        cond do
          not application_allowed?(application) -> {:error, :invalid_client}
          redirect_uri not in registration.redirect_uris -> {:error, :invalid_redirect_uri}
          not exact_scopes?(scopes, registration.scopes) -> {:error, :invalid_scope}
          Keyword.get(opts, :code_challenge_method) != "S256" -> {:error, :pkce_required}
          not is_binary(Keyword.get(opts, :code_challenge)) -> {:error, :pkce_required}
          true -> :ok
        end
    end
  end

  def validate_authorization(_application, _redirect_uri, _scopes, _opts),
    do: {:error, :invalid_request}

  def validate_token_scopes(%OAuthApplication{} = application, scopes) when is_binary(scopes) do
    case get_by_application_id(application.id) do
      nil ->
        :ok

      %OAuthRegistration{scopes: registered} ->
        if exact_scopes?(scopes, registered), do: :ok, else: {:error, :invalid_scope}
    end
  end

  defp register_locked(manifest) do
    lock_origin(manifest.origin)
    fingerprint = fingerprint(manifest)

    case get_by_origin(manifest.origin) do
      %OAuthRegistration{manifest_fingerprint: ^fingerprint} = registration ->
        {registration, :existing}

      %OAuthRegistration{} ->
        Repo.rollback(:manifest_changed)

      nil ->
        {create_registration(manifest, fingerprint), :created}
    end
  end

  defp create_registration(manifest, fingerprint) do
    oauth = manifest.oauth

    application_attrs = %{
      "client_name" => manifest.name,
      "website" => manifest.home_url,
      "redirect_uris" => oauth.redirect_uris,
      "scopes" => Enum.join(oauth.scopes, " ")
    }

    case OAuth.create_application(application_attrs) do
      {:ok, application} ->
        attrs = %{
          oauth_application_id: application.id,
          app_origin: manifest.origin,
          redirect_uris: oauth.redirect_uris,
          scopes: oauth.scopes,
          capabilities: manifest.capabilities,
          manifest_fingerprint: fingerprint,
          registered_at: DateTime.utc_now()
        }

        case %OAuthRegistration{} |> OAuthRegistration.changeset(attrs) |> Repo.insert() do
          {:ok, registration} -> registration
          {:error, changeset} -> Repo.rollback(changeset)
        end

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp lock_origin(origin) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtext($1))",
      [origin]
    )
  end

  defp fingerprint(manifest) do
    manifest.oauth
    |> then(fn oauth ->
      {oauth.redirect_uris, oauth.scopes, manifest.capabilities}
    end)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp require_origin_allowed(origin) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) ->
        if MiniApps.domain_allowed?(host), do: :ok, else: {:error, :domain_denied}

      _ ->
        {:error, :invalid_origin}
    end
  end

  defp origin_allowed?(origin) do
    case require_origin_allowed(origin) do
      :ok -> true
      _ -> false
    end
  end

  defp exact_scopes?(scopes, registered) when is_binary(scopes) and is_list(registered) do
    MapSet.new(Scopes.parse(scopes)) == MapSet.new(registered)
  end
end
