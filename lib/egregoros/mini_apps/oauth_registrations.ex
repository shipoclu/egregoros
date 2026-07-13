defmodule Egregoros.MiniApps.OAuthRegistrations do
  @moduledoc false

  @default_authorization_max_age_seconds 31_536_000

  import Ecto.Query

  alias Egregoros.MiniApps
  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.GrantLock
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.OAuthRegistration
  alias Egregoros.MiniApps.Permissions
  alias Egregoros.OAuth
  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.OAuth.AuthorizationCode
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
    with :ok <- require_origin_allowed(manifest.origin),
         {:ok, _declaration, _status} <- Declarations.ensure(manifest) do
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

  def application_allowed?(%OAuthApplication{client_type: :confidential} = application) do
    is_nil(get_by_application_id(application.id))
  end

  def application_allowed?(%OAuthApplication{client_type: :public_mini_app} = application) do
    case get_by_application_id(application.id) do
      %OAuthRegistration{} = registration ->
        registration_allowed?(registration, application)

      nil ->
        false
    end
  end

  def application_allowed?(_application), do: false

  def registration_allowed?(
        %OAuthRegistration{oauth_application_id: application_id} = registration,
        %OAuthApplication{id: application_id, client_type: :public_mini_app} = application
      ) do
    origin_allowed?(registration.app_origin) and
      registration.redirect_uris == application.redirect_uris and
      exact_scopes?(application.scopes, registration.scopes)
  end

  def registration_allowed?(_registration, _application), do: false

  def public_client?(%OAuthApplication{client_type: :public_mini_app}), do: true

  def public_client?(_application), do: false

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
            (is_nil(token.refresh_expires_at) or token.refresh_expires_at > ^now),
        select: token.scopes
      )
      |> Repo.all()
      |> Enum.any?(&identity_scope?/1)
    else
      _ -> false
    end
  end

  def active_user_grant?(_origin, _user_id), do: false

  def list_user_grants(user_id) when is_binary(user_id) do
    now = DateTime.utc_now()

    from(registration in OAuthRegistration,
      join: token in Token,
      on: token.application_id == registration.oauth_application_id,
      where:
        token.user_id == ^user_id and is_nil(token.revoked_at) and
          (is_nil(token.refresh_expires_at) or token.refresh_expires_at > ^now),
      order_by: [desc: registration.registered_at, asc: registration.app_origin],
      select: %{
        id: registration.id,
        app_origin: registration.app_origin,
        registered_scopes: registration.scopes,
        capabilities: registration.capabilities,
        registered_at: registration.registered_at,
        token_scopes: token.scopes,
        authorization_expires_at: token.refresh_expires_at
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {_id, rows} -> aggregate_user_grant(rows) end)
    |> Enum.sort_by(&{DateTime.to_unix(&1.registered_at, :microsecond), &1.app_origin}, :desc)
  rescue
    ArgumentError -> []
    Ecto.Query.CastError -> []
  end

  def list_user_grants(_user_id), do: []

  def revoke_user_grant(origin, user_id) when is_binary(origin) and is_binary(user_id) do
    case get_by_origin(origin) do
      %OAuthRegistration{oauth_application_id: application_id} ->
        now = DateTime.utc_now()

        case Repo.transaction(fn ->
               GrantLock.acquire(user_id, origin)

               from(token in Token,
                 where:
                   token.application_id == ^application_id and token.user_id == ^user_id and
                     is_nil(token.revoked_at)
               )
               |> Repo.update_all(set: [revoked_at: now])

               from(code in AuthorizationCode,
                 where: code.application_id == ^application_id and code.user_id == ^user_id
               )
               |> Repo.delete_all()
             end) do
          {:ok, _result} ->
            Permissions.notify_revoked(user_id, origin, :oauth)
            :ok

          {:error, _reason} ->
            {:error, :revocation_failed}
        end

      nil ->
        :ok
    end
  rescue
    ArgumentError -> :ok
    Ecto.Query.CastError -> :ok
  end

  def revoke_user_grant(_origin, _user_id), do: :ok

  def validate_authorization(%OAuthApplication{} = application, redirect_uri, scopes, opts)
      when is_binary(redirect_uri) and is_binary(scopes) and is_list(opts) do
    case {application.client_type, get_by_application_id(application.id)} do
      {:confidential, nil} ->
        :ok

      {:public_mini_app, %OAuthRegistration{} = registration} ->
        cond do
          not application_allowed?(application) -> {:error, :invalid_client}
          redirect_uri not in registration.redirect_uris -> {:error, :invalid_redirect_uri}
          not subset_scopes?(scopes, registration.scopes) -> {:error, :invalid_scope}
          Keyword.get(opts, :code_challenge_method) != "S256" -> {:error, :pkce_required}
          not is_binary(Keyword.get(opts, :code_challenge)) -> {:error, :pkce_required}
          true -> validate_grant_lifetime(application, scopes, opts)
        end

      _ ->
        {:error, :invalid_client}
    end
  end

  def validate_authorization(_application, _redirect_uri, _scopes, _opts),
    do: {:error, :invalid_request}

  def validate_token_scopes(%OAuthApplication{} = application, scopes) when is_binary(scopes) do
    case {application.client_type, get_by_application_id(application.id)} do
      {:confidential, nil} ->
        :ok

      {:public_mini_app, %OAuthRegistration{scopes: registered}} ->
        if subset_scopes?(scopes, registered), do: :ok, else: {:error, :invalid_scope}

      _ ->
        {:error, :invalid_client}
    end
  end

  def authorization_lifetime(%OAuthApplication{} = application, scopes, requested)
      when is_binary(scopes) do
    case {application.client_type, get_by_application_id(application.id)} do
      {:public_mini_app, %OAuthRegistration{} = registration} ->
        with true <- subset_scopes?(scopes, registration.scopes),
             {:ok, requested_seconds} <- optional_positive_integer(requested),
             {:ok, scope_max} <- scope_authorization_maximum(registration, scopes) do
          server_max = authorization_server_max_age_seconds()
          scope_max = min(scope_max, server_max)

          case requested_seconds do
            nil -> {:ok, scope_max}
            seconds when seconds <= scope_max -> {:ok, seconds}
            _seconds -> {:error, :invalid_authorization_lifetime}
          end
        else
          false -> {:error, :invalid_scope}
          {:error, _reason} = error -> error
        end

      {:confidential, nil} ->
        with {:ok, requested_seconds} <- optional_positive_integer(requested) do
          case requested_seconds do
            nil -> {:ok, nil}
            seconds -> {:ok, min(seconds, authorization_server_max_age_seconds())}
          end
        end

      _ ->
        {:error, :invalid_client}
    end
  end

  def authorization_lifetime(_application, _scopes, _requested),
    do: {:error, :invalid_request}

  defp register_locked(manifest) do
    lock_origin(manifest.origin)
    fingerprint = fingerprint(manifest)

    case get_by_origin(manifest.origin) do
      %OAuthRegistration{manifest_fingerprint: ^fingerprint} = registration ->
        {registration, :existing}

      %OAuthRegistration{} = registration ->
        if legacy_fingerprint_compatible?(registration, manifest) do
          registration
          |> Ecto.Changeset.change(
            manifest_fingerprint: fingerprint,
            scope_authorization_max_age_seconds: %{}
          )
          |> Repo.update!()
          |> then(&{&1, :existing})
        else
          Repo.rollback(:manifest_changed)
        end

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

    case OAuth.create_application(application_attrs, client_type: :public_mini_app) do
      {:ok, application} ->
        attrs = %{
          oauth_application_id: application.id,
          app_origin: manifest.origin,
          redirect_uris: oauth.redirect_uris,
          scopes: oauth.scopes,
          scope_authorization_max_age_seconds:
            Map.get(oauth, :scope_authorization_max_age_seconds, %{}),
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
      {oauth.redirect_uris, oauth.scopes,
       Map.get(oauth, :scope_authorization_max_age_seconds, %{}), manifest.capabilities,
       manifest.wallet}
    end)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp legacy_fingerprint_compatible?(registration, manifest) do
    oauth = manifest.oauth

    if Map.get(oauth, :scope_authorization_max_age_seconds, %{}) == %{} do
      legacy =
        {oauth.redirect_uris, oauth.scopes, manifest.capabilities, manifest.wallet}
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))

      registration.manifest_fingerprint == legacy
    else
      false
    end
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

  defp subset_scopes?(scopes, registered) when is_binary(scopes) and is_list(registered) do
    raw = String.split(scopes, ~r/\s+/, trim: true)
    parsed = Scopes.parse(scopes)

    raw == parsed and length(parsed) in 1..32 and
      ("identify" in parsed or "read" in parsed) and
      MapSet.subset?(MapSet.new(parsed), MapSet.new(registered))
  end

  defp identity_scope?(scopes) when is_binary(scopes) do
    parsed = Scopes.parse(scopes)
    "identify" in parsed or "read" in parsed
  end

  defp aggregate_user_grant([first | _] = rows) do
    scope_expirations =
      Enum.reduce(rows, %{}, fn row, expirations ->
        Enum.reduce(Scopes.parse(row.token_scopes), expirations, fn scope, acc ->
          Map.update(
            acc,
            scope,
            row.authorization_expires_at,
            &later_expiration(&1, row.authorization_expires_at)
          )
        end)
      end)

    %{
      id: first.id,
      app_origin: first.app_origin,
      scopes: Enum.filter(first.registered_scopes, &Map.has_key?(scope_expirations, &1)),
      scope_expirations: scope_expirations,
      capabilities: first.capabilities,
      registered_at: first.registered_at
    }
  end

  defp later_expiration(nil, right), do: right
  defp later_expiration(left, nil), do: left

  defp later_expiration(%DateTime{} = left, %DateTime{} = right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp optional_positive_integer(nil), do: {:ok, nil}
  defp optional_positive_integer(""), do: {:ok, nil}

  defp optional_positive_integer(value) when is_integer(value) and value in 300..31_536_000,
    do: {:ok, value}

  defp optional_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds in 300..31_536_000 -> {:ok, seconds}
      _ -> {:error, :invalid_authorization_lifetime}
    end
  end

  defp optional_positive_integer(_value), do: {:error, :invalid_authorization_lifetime}

  defp validate_grant_lifetime(application, scopes, opts) do
    case authorization_lifetime(application, scopes, Keyword.get(opts, :grant_ttl_seconds)) do
      {:ok, _seconds} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp scope_authorization_maximum(registration, scopes) do
    server_max = authorization_server_max_age_seconds()
    ages = registration.scope_authorization_max_age_seconds

    if is_map(ages) do
      values = Enum.map(Scopes.parse(scopes), &Map.get(ages, &1, server_max))

      if Enum.all?(values, &(is_integer(&1) and &1 in 300..31_536_000)),
        do: {:ok, Enum.min(values)},
        else: {:error, :invalid_client}
    else
      {:error, :invalid_client}
    end
  end

  defp authorization_server_max_age_seconds do
    case Egregoros.Config.get(
           :oauth_refresh_token_ttl_seconds,
           @default_authorization_max_age_seconds
         ) do
      seconds when is_integer(seconds) and seconds in 300..31_536_000 -> seconds
      _ -> @default_authorization_max_age_seconds
    end
  end
end
