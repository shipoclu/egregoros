defmodule Egregoros.OAuth do
  import Ecto.Query, only: [from: 2]

  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.OAuth.AuthorizationCode
  alias Egregoros.OAuth.Scopes
  alias Egregoros.OAuth.Token
  alias Egregoros.MiniApps.GrantLock
  alias Egregoros.MiniApps.OAuthRegistration
  alias Egregoros.MiniApps.OAuthRegistrations, as: MiniAppOAuthRegistrations
  alias Egregoros.Repo
  alias Egregoros.User

  @default_code_ttl_seconds 600
  @default_access_token_ttl_seconds 3_600
  @default_refresh_token_ttl_seconds 31_536_000

  def create_application(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    client_type = Keyword.get(opts, :client_type, :confidential)

    if client_type in [:confidential, :public_mini_app] do
      now = DateTime.utc_now()

      application_attrs = %{
        name: Map.get(attrs, "client_name") || Map.get(attrs, :client_name) || "App",
        website: Map.get(attrs, "website") || Map.get(attrs, :website),
        redirect_uris:
          parse_redirect_uris(Map.get(attrs, "redirect_uris") || Map.get(attrs, :redirect_uris)),
        scopes: Map.get(attrs, "scopes") || Map.get(attrs, :scopes) || "",
        kind: Map.get(attrs, "fap:kind") || Map.get(attrs, :kind),
        client_id: generate_token(32),
        client_secret: generate_token(48),
        inserted_at: now,
        updated_at: now
      }

      %OAuthApplication{client_type: client_type}
      |> OAuthApplication.changeset(application_attrs)
      |> Repo.insert()
    else
      {:error, :invalid_client_type}
    end
  end

  def get_application_by_client_id(nil), do: nil

  def get_application_by_client_id(client_id) when is_binary(client_id) do
    Repo.get_by(OAuthApplication, client_id: client_id)
  end

  def redirect_uri_allowed?(%OAuthApplication{redirect_uris: redirect_uris}, redirect_uri)
      when is_binary(redirect_uri) and is_list(redirect_uris) do
    redirect_uri in redirect_uris
  end

  def redirect_uri_allowed?(_app, _redirect_uri), do: false

  def create_authorization_code(
        %OAuthApplication{} = application,
        %User{} = user,
        redirect_uri,
        scopes,
        opts \\ []
      )
      when is_binary(redirect_uri) and is_binary(scopes) and is_list(opts) do
    with :ok <-
           MiniAppOAuthRegistrations.validate_authorization(
             application,
             redirect_uri,
             scopes,
             opts
           ),
         {:ok, grant_ttl_seconds} <-
           MiniAppOAuthRegistrations.authorization_lifetime(
             application,
             scopes,
             Keyword.get(opts, :grant_ttl_seconds)
           ) do
      if redirect_uri_allowed?(application, redirect_uri) do
        if Scopes.subset?(scopes, application.scopes) do
          with {:ok, pkce_attrs} <- pkce_attrs(application, opts),
               {:ok, grant_expires_at} <-
                 grant_expiration(Keyword.put(opts, :grant_ttl_seconds, grant_ttl_seconds)) do
            ttl_seconds =
              Egregoros.Config.get(:oauth_code_ttl_seconds, @default_code_ttl_seconds)

            expires_at = DateTime.add(DateTime.utc_now(), ttl_seconds, :second)

            attrs =
              Map.merge(pkce_attrs, %{
                code: generate_token(32),
                redirect_uri: redirect_uri,
                scopes: scopes,
                expires_at: expires_at,
                grant_expires_at: grant_expires_at,
                user_id: user.id,
                application_id: application.id
              })

            %AuthorizationCode{}
            |> AuthorizationCode.changeset(attrs)
            |> Repo.insert()
          end
        else
          {:error, :invalid_scope}
        end
      else
        {:error, :invalid_redirect_uri}
      end
    end
  end

  def get_authorization_code(nil), do: nil

  def get_authorization_code(code) when is_binary(code) do
    Repo.get_by(AuthorizationCode, code: code)
  end

  def pending_browser_authorization_code?(
        code,
        application_id,
        user_id,
        redirect_uri,
        scopes,
        code_challenge
      )
      when is_binary(code) and is_binary(application_id) and is_binary(user_id) and
             is_binary(redirect_uri) and is_binary(scopes) and is_binary(code_challenge) do
    now = DateTime.utc_now()

    from(c in AuthorizationCode,
      where:
        c.code == ^code and c.application_id == ^application_id and c.user_id == ^user_id and
          c.redirect_uri == ^redirect_uri and c.scopes == ^scopes and
          c.code_challenge == ^code_challenge and c.code_challenge_method == "S256" and
          c.expires_at > ^now and (is_nil(c.grant_expires_at) or c.grant_expires_at > ^now)
    )
    |> Repo.exists?()
  end

  def pending_browser_authorization_code?(
        _code,
        _application_id,
        _user_id,
        _redirect_uri,
        _scopes,
        _code_challenge
      ),
      do: false

  def exchange_code_for_token(
        %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client_id,
          "redirect_uri" => redirect_uri
        } = params
      )
      when is_binary(code) and is_binary(client_id) and is_binary(redirect_uri) do
    case get_application_by_client_id(client_id) do
      %OAuthApplication{} = application ->
        case authenticate_token_client(application, params) do
          {:ok, client_auth} ->
            exchange_authorization_code(application, code, redirect_uri, params, client_auth)

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        {:error, :invalid_client}
    end
  end

  def exchange_code_for_token(
        %{
          "grant_type" => "refresh_token",
          "refresh_token" => refresh_token,
          "client_id" => client_id
        } = params
      )
      when is_binary(refresh_token) and is_binary(client_id) do
    refresh_token = String.trim(refresh_token)

    with %OAuthApplication{} = application <- get_application_by_client_id(client_id),
         {:ok, client_auth} <- authenticate_token_client(application, params) do
      rotate_refresh_token(application, refresh_token, params, client_auth)
    else
      nil -> {:error, :invalid_client}
      {:error, _} = error -> error
      _ -> {:error, :invalid_grant}
    end
  end

  def exchange_code_for_token(
        %{
          "grant_type" => "client_credentials",
          "client_id" => client_id,
          "client_secret" => client_secret
        } = params
      )
      when is_binary(client_id) and is_binary(client_secret) do
    client_id = String.trim(client_id)
    client_secret = String.trim(client_secret)

    with %OAuthApplication{} = application <- get_application_by_client_id(client_id),
         false <- MiniAppOAuthRegistrations.public_client?(application),
         true <- MiniAppOAuthRegistrations.application_allowed?(application),
         true <- Plug.Crypto.secure_compare(application.client_secret, client_secret),
         :ok <- validate_redirect_uri_param(application, params),
         {:ok, scopes} <- client_credentials_scopes(params, application),
         {:ok, %Token{} = token} <- create_token(application, nil, scopes) do
      {:ok, token}
    else
      nil -> {:error, :invalid_client}
      true -> {:error, :unauthorized_client}
      false -> {:error, :invalid_client}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def exchange_code_for_token(_params), do: {:error, :unsupported_grant_type}

  def get_user_by_token(nil), do: nil

  def get_user_by_token(token) when is_binary(token) do
    case get_token(token) do
      %Token{user: %User{} = user} -> user
      _ -> nil
    end
  end

  def get_token(nil), do: nil

  def get_token(token) when is_binary(token) do
    now = DateTime.utc_now()
    token_digest = digest_token(token)

    from(t in Token,
      where:
        t.token_digest == ^token_digest and is_nil(t.revoked_at) and
          (is_nil(t.expires_at) or t.expires_at > ^now),
      left_join: u in assoc(t, :user),
      left_join: a in assoc(t, :application),
      preload: [user: u, application: a]
    )
    |> Repo.one()
    |> enforce_application_policy()
  end

  def revoke_token(%{"token" => token, "client_id" => client_id} = params)
      when is_binary(token) and is_binary(client_id) do
    token = String.trim(token)

    with %OAuthApplication{} = application <- get_application_by_client_id(client_id),
         {:ok, client_auth} <- authenticate_token_client(application, params) do
      revoke_authenticated_token(application, token, client_auth)
    else
      nil -> {:error, :invalid_client}
      {:error, _reason} -> {:error, :invalid_client}
    end
  end

  def revoke_token(_params), do: {:error, :invalid_request}

  defp create_token(application, user_id, scopes, opts \\ [])

  defp create_token(%OAuthApplication{} = application, user_id, scopes, opts)
       when is_binary(user_id) and is_binary(scopes) and is_list(opts) do
    now = DateTime.utc_now()
    ttl_seconds = access_token_ttl_seconds()
    refresh_ttl_seconds = refresh_token_ttl_seconds()

    refresh_expires_at =
      absolute_grant_expiration(now, refresh_ttl_seconds, Keyword.get(opts, :grant_expires_at))

    expires_at = earlier(DateTime.add(now, ttl_seconds, :second), refresh_expires_at)

    raw_token = generate_token(48)
    raw_refresh_token = generate_token(48)

    %Token{}
    |> Token.changeset(%{
      token_digest: digest_token(raw_token),
      refresh_token_digest: digest_token(raw_refresh_token),
      family_id: Keyword.get(opts, :family_id, Ecto.UUID.generate()),
      scopes: scopes,
      user_id: user_id,
      application_id: application.id,
      expires_at: expires_at,
      refresh_expires_at: refresh_expires_at
    })
    |> Repo.insert()
    |> case do
      {:ok, %Token{} = token} ->
        {:ok, %{token | token: raw_token, refresh_token: raw_refresh_token}}

      {:error, _} = error ->
        error
    end
  end

  defp create_token(%OAuthApplication{} = application, nil, scopes, opts)
       when is_binary(scopes) and is_list(opts) do
    now = DateTime.utc_now()
    ttl_seconds = access_token_ttl_seconds()
    refresh_ttl_seconds = refresh_token_ttl_seconds()

    refresh_expires_at =
      absolute_grant_expiration(now, refresh_ttl_seconds, Keyword.get(opts, :grant_expires_at))

    expires_at = earlier(DateTime.add(now, ttl_seconds, :second), refresh_expires_at)

    raw_token = generate_token(48)
    raw_refresh_token = generate_token(48)

    %Token{}
    |> Token.changeset(%{
      token_digest: digest_token(raw_token),
      refresh_token_digest: digest_token(raw_refresh_token),
      family_id: Keyword.get(opts, :family_id, Ecto.UUID.generate()),
      scopes: scopes,
      user_id: nil,
      application_id: application.id,
      expires_at: expires_at,
      refresh_expires_at: refresh_expires_at
    })
    |> Repo.insert()
    |> case do
      {:ok, %Token{} = token} ->
        {:ok, %{token | token: raw_token, refresh_token: raw_refresh_token}}

      {:error, _} = error ->
        error
    end
  end

  defp exchange_authorization_code(
         application,
         code,
         redirect_uri,
         params,
         :confidential
       ) do
    exchange_authorization_code_locked(application, code, redirect_uri, params, nil)
  end

  defp exchange_authorization_code(
         %OAuthApplication{id: application_id} = application,
         code,
         redirect_uri,
         params,
         {:public, app_origin}
       ) do
    case get_authorization_code(code) do
      %AuthorizationCode{application_id: ^application_id, user_id: user_id}
      when is_binary(user_id) ->
        exchange_authorization_code_locked(
          application,
          code,
          redirect_uri,
          params,
          {user_id, app_origin}
        )

      _ ->
        {:error, :invalid_grant}
    end
  end

  defp exchange_authorization_code_locked(
         application,
         code,
         redirect_uri,
         params,
         grant_lock
       ) do
    case Repo.transaction(fn ->
           :ok = acquire_grant_lock(grant_lock)

           case current_locked_application(application, grant_lock) do
             {:ok, current_application} ->
               auth_code =
                 from(c in AuthorizationCode, where: c.code == ^code, lock: "FOR UPDATE")
                 |> Repo.one()

               with %AuthorizationCode{} <- auth_code,
                    true <- auth_code.application_id == current_application.id,
                    true <- grant_user_matches?(auth_code, grant_lock),
                    true <- auth_code.redirect_uri == redirect_uri,
                    true <- DateTime.compare(auth_code.expires_at, DateTime.utc_now()) == :gt,
                    true <- grant_active?(auth_code.grant_expires_at),
                    :ok <- verify_pkce(auth_code, params),
                    {:ok, %Token{} = token} <-
                      create_token(
                        current_application,
                        auth_code.user_id,
                        auth_code.scopes,
                        grant_expires_at: auth_code.grant_expires_at
                      ),
                    {:ok, _deleted} <- Repo.delete(auth_code) do
                 token
               else
                 _ -> Repo.rollback(:invalid_grant)
               end

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, %Token{} = token} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_pkce(%AuthorizationCode{code_challenge: nil}, _params), do: :ok

  defp verify_pkce(
         %AuthorizationCode{code_challenge: challenge, code_challenge_method: "S256"},
         params
       )
       when is_binary(challenge) and is_map(params) do
    with verifier when is_binary(verifier) <- Map.get(params, "code_verifier"),
         true <- valid_code_verifier?(verifier) do
      computed =
        :crypto.hash(:sha256, verifier)
        |> Base.url_encode64(padding: false)

      if byte_size(computed) == byte_size(challenge) and
           Plug.Crypto.secure_compare(computed, challenge),
         do: :ok,
         else: {:error, :invalid_grant}
    else
      _ -> {:error, :invalid_grant}
    end
  end

  defp verify_pkce(_auth_code, _params), do: {:error, :invalid_grant}

  defp valid_code_verifier?(verifier) when is_binary(verifier) do
    byte_size(verifier) in 43..128 and
      String.match?(verifier, ~r/^[A-Za-z0-9._~-]+$/)
  end

  defp rotate_refresh_token(application, refresh_token, params, :confidential) do
    refresh_digest = digest_token(refresh_token)
    rotate_refresh_token_locked(application, refresh_digest, params, nil)
  end

  defp rotate_refresh_token(
         %OAuthApplication{id: application_id} = application,
         refresh_token,
         params,
         {:public, app_origin}
       ) do
    refresh_digest = digest_token(refresh_token)

    case token_by_refresh_digest(application_id, refresh_digest) do
      %Token{user_id: user_id} when is_binary(user_id) ->
        rotate_refresh_token_locked(
          application,
          refresh_digest,
          params,
          {user_id, app_origin}
        )

      _ ->
        {:error, :invalid_grant}
    end
  end

  defp rotate_refresh_token_locked(application, refresh_digest, params, grant_lock) do
    expected_user_id = grant_lock_user_id(grant_lock)

    case Repo.transaction(fn ->
           :ok = acquire_grant_lock(grant_lock)

           case current_locked_application(application, grant_lock) do
             {:ok, current_application} ->
               old_token =
                 token_by_refresh_digest(current_application.id, refresh_digest, lock: true)

               rotate_locked_refresh_token(
                 old_token,
                 current_application,
                 params,
                 expected_user_id
               )

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, {:ok, %Token{} = token}} -> {:ok, token}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rotate_locked_refresh_token(nil, _application, _params, _expected_user_id),
    do: {:error, :invalid_grant}

  defp rotate_locked_refresh_token(
         %Token{application_id: token_application_id},
         %OAuthApplication{id: application_id},
         _params,
         _expected_user_id
       )
       when token_application_id != application_id,
       do: {:error, :invalid_grant}

  defp rotate_locked_refresh_token(
         %Token{user_id: token_user_id},
         _application,
         _params,
         expected_user_id
       )
       when is_binary(expected_user_id) and token_user_id != expected_user_id,
       do: {:error, :invalid_grant}

  defp rotate_locked_refresh_token(
         %Token{consumed_at: consumed_at, revoked_at: revoked_at} = token,
         _application,
         _params,
         _expected_user_id
       )
       when not is_nil(consumed_at) or not is_nil(revoked_at) do
    _ = revoke_token_family(token)
    {:error, :invalid_grant}
  end

  defp rotate_locked_refresh_token(
         %Token{} = old_token,
         application,
         params,
         _expected_user_id
       ) do
    if refresh_token_active?(old_token) do
      with {:ok, scopes} <- refresh_scopes(params, old_token, application),
           :ok <- MiniAppOAuthRegistrations.validate_token_scopes(application, scopes),
           {:ok, _consumed} <-
             old_token
             |> Token.changeset(%{
               consumed_at: DateTime.utc_now(),
               revoked_at: DateTime.utc_now()
             })
             |> Repo.update(),
           {:ok, %Token{} = token} <-
             create_token(application, old_token.user_id, scopes,
               family_id: old_token.family_id,
               grant_expires_at: old_token.refresh_expires_at
             ) do
        {:ok, token}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      {:error, :invalid_grant}
    end
  end

  defp revoke_token_family(%Token{application_id: application_id, family_id: family_id})
       when is_binary(application_id) and is_binary(family_id) do
    from(t in Token,
      where:
        t.application_id == ^application_id and t.family_id == ^family_id and
          is_nil(t.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: DateTime.utc_now()])

    :ok
  end

  defp revoke_token_family(_token), do: :ok

  defp refresh_token_active?(%Token{refresh_expires_at: nil}), do: true

  defp refresh_token_active?(%Token{refresh_expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  defp refresh_token_active?(_), do: false

  defp grant_active?(nil), do: true

  defp grant_active?(%DateTime{} = expires_at) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  defp grant_active?(_), do: false

  defp refresh_scopes(params, %Token{} = old_token, %OAuthApplication{} = application) do
    case Map.get(params, "scope") do
      scope when is_binary(scope) and scope != "" ->
        scope = String.trim(scope)

        cond do
          not Scopes.subset?(scope, old_token.scopes) ->
            {:error, :invalid_scope}

          not Scopes.subset?(scope, application.scopes) ->
            {:error, :invalid_scope}

          true ->
            {:ok, scope}
        end

      _ ->
        {:ok, old_token.scopes}
    end
  end

  defp validate_redirect_uri_param(%OAuthApplication{} = application, params)
       when is_map(params) do
    case Map.get(params, "redirect_uri") do
      redirect_uri when is_binary(redirect_uri) ->
        redirect_uri = String.trim(redirect_uri)

        if redirect_uri == "" or redirect_uri_allowed?(application, redirect_uri) do
          :ok
        else
          {:error, :invalid_redirect_uri}
        end

      _ ->
        :ok
    end
  end

  defp validate_redirect_uri_param(_application, _params), do: :ok

  defp client_credentials_scopes(params, %OAuthApplication{} = application) when is_map(params) do
    scope =
      case Map.get(params, "scope") do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    scopes = if scope == "", do: application.scopes, else: scope

    if Scopes.subset?(scopes, application.scopes) do
      {:ok, scopes}
    else
      {:error, :invalid_scope}
    end
  end

  defp revoke_authenticated_token(application, token, :confidential) do
    _ = revoke_token_record_for_token(application.id, token)
    :ok
  end

  defp revoke_authenticated_token(
         %OAuthApplication{id: application_id},
         token,
         {:public, app_origin}
       ) do
    token_digest = digest_token(token)

    case token_by_presented_digest(application_id, token_digest) do
      %Token{user_id: user_id} when is_binary(user_id) ->
        case Repo.transaction(fn ->
               GrantLock.acquire(user_id, app_origin)

               case token_by_presented_digest(application_id, token_digest, lock: true) do
                 %Token{user_id: ^user_id} = token -> revoke_token_family(token)
                 _ -> :ok
               end
             end) do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :ok
    end
  end

  defp token_by_presented_digest(application_id, token_digest, opts \\ []) do
    query =
      from(t in Token,
        where:
          t.application_id == ^application_id and
            (t.token_digest == ^token_digest or t.refresh_token_digest == ^token_digest)
      )

    query
    |> maybe_lock_query(opts)
    |> Repo.one()
  end

  defp token_by_refresh_digest(application_id, refresh_digest, opts \\ []) do
    query =
      from(t in Token,
        where:
          t.application_id == ^application_id and
            t.refresh_token_digest == ^refresh_digest
      )

    query
    |> maybe_lock_query(opts)
    |> Repo.one()
  end

  defp maybe_lock_query(query, opts) when is_list(opts) do
    if Keyword.get(opts, :lock, false),
      do: from(row in query, lock: "FOR UPDATE"),
      else: query
  end

  defp acquire_grant_lock(nil), do: :ok

  defp acquire_grant_lock({user_id, app_origin}) do
    GrantLock.acquire(user_id, app_origin)
  end

  defp current_locked_application(%OAuthApplication{} = application, nil),
    do: {:ok, application}

  defp current_locked_application(
         %OAuthApplication{id: application_id, client_id: client_id},
         {_user_id, app_origin}
       ) do
    with %OAuthApplication{client_type: :public_mini_app, client_id: ^client_id} = current <-
           Repo.get(OAuthApplication, application_id),
         %OAuthRegistration{app_origin: ^app_origin} = registration <-
           MiniAppOAuthRegistrations.get_by_application_id(application_id),
         true <- MiniAppOAuthRegistrations.registration_allowed?(registration, current) do
      {:ok, current}
    else
      _ -> {:error, :invalid_client}
    end
  end

  defp grant_lock_user_id(nil), do: nil
  defp grant_lock_user_id({user_id, _app_origin}), do: user_id

  defp grant_user_matches?(_auth_code, nil), do: true

  defp grant_user_matches?(%AuthorizationCode{user_id: user_id}, {user_id, _app_origin}),
    do: true

  defp grant_user_matches?(_auth_code, _grant_lock), do: false

  defp revoke_token_record_for_token(application_id, token)
       when is_binary(application_id) and is_binary(token) do
    now = DateTime.utc_now()
    token_digest = digest_token(token)

    from(t in Token,
      where:
        t.application_id == ^application_id and is_nil(t.revoked_at) and
          (t.token_digest == ^token_digest or t.refresh_token_digest == ^token_digest)
    )
    |> Repo.update_all(set: [revoked_at: now])
  end

  defp revoke_token_record_for_token(_application_id, _token), do: :ok

  defp enforce_application_policy(nil), do: nil

  defp enforce_application_policy(%Token{application: %OAuthApplication{} = application} = token) do
    if MiniAppOAuthRegistrations.application_allowed?(application) do
      token
    else
      now = DateTime.utc_now()

      from(t in Token,
        where: t.application_id == ^application.id and is_nil(t.revoked_at)
      )
      |> Repo.update_all(set: [revoked_at: now])

      nil
    end
  end

  defp enforce_application_policy(%Token{} = token), do: token

  defp authenticate_token_client(%OAuthApplication{} = application, params) when is_map(params) do
    case application.client_type do
      :public_mini_app ->
        case MiniAppOAuthRegistrations.get_by_application_id(application.id) do
          %OAuthRegistration{} = registration ->
            if not Map.has_key?(params, "client_secret") and
                 MiniAppOAuthRegistrations.registration_allowed?(registration, application),
               do: {:ok, {:public, registration.app_origin}},
               else: {:error, :invalid_client}

          nil ->
            {:error, :invalid_client}
        end

      :confidential ->
        case Map.get(params, "client_secret") do
          client_secret when is_binary(client_secret) ->
            if MiniAppOAuthRegistrations.application_allowed?(application) and
                 Plug.Crypto.secure_compare(application.client_secret, client_secret),
               do: {:ok, :confidential},
               else: {:error, :invalid_grant}

          _ ->
            {:error, :invalid_grant}
        end

      _ ->
        {:error, :invalid_client}
    end
  end

  defp authenticate_token_client(_application, _params), do: {:error, :invalid_client}

  defp pkce_attrs(application, opts) do
    challenge = normalize_optional_string(Keyword.get(opts, :code_challenge))
    method = normalize_optional_string(Keyword.get(opts, :code_challenge_method))

    cond do
      is_nil(challenge) and is_nil(method) and public_native_application?(application) ->
        {:error, :pkce_required}

      is_nil(challenge) and is_nil(method) ->
        {:ok, %{}}

      method == "S256" and valid_code_challenge?(challenge) ->
        {:ok, %{code_challenge: challenge, code_challenge_method: "S256"}}

      true ->
        {:error, :invalid_code_challenge}
    end
  end

  defp valid_code_challenge?(challenge) when is_binary(challenge) do
    byte_size(challenge) in 43..128 and
      String.match?(challenge, ~r/^[A-Za-z0-9_-]+$/)
  end

  defp valid_code_challenge?(_challenge), do: false

  defp public_native_application?(%OAuthApplication{redirect_uris: redirect_uris}) do
    Enum.any?(redirect_uris, fn redirect_uri ->
      case URI.parse(redirect_uri) do
        %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1", "::1"] ->
          true

        %URI{scheme: scheme, host: nil, path: "/" <> _}
        when is_binary(scheme) and scheme != "urn" ->
          true

        _ ->
          false
      end
    end)
  end

  defp public_native_application?(_application), do: false

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp access_token_ttl_seconds do
    case Egregoros.Config.get(
           :oauth_access_token_ttl_seconds,
           @default_access_token_ttl_seconds
         ) do
      ttl when is_integer(ttl) and ttl >= 1 -> ttl
      _invalid -> @default_access_token_ttl_seconds
    end
  end

  defp refresh_token_ttl_seconds do
    case Egregoros.Config.get(
           :oauth_refresh_token_ttl_seconds,
           @default_refresh_token_ttl_seconds
         ) do
      ttl when is_integer(ttl) and ttl >= 1 -> ttl
      _invalid -> @default_refresh_token_ttl_seconds
    end
  end

  defp grant_expiration(opts) do
    case Keyword.get(opts, :grant_ttl_seconds) do
      nil ->
        {:ok, nil}

      seconds when is_integer(seconds) and seconds >= 1 ->
        seconds = min(seconds, refresh_token_ttl_seconds())
        {:ok, DateTime.add(DateTime.utc_now(), seconds, :second)}

      _ ->
        {:error, :invalid_authorization_lifetime}
    end
  end

  defp absolute_grant_expiration(now, refresh_ttl_seconds, nil),
    do: DateTime.add(now, refresh_ttl_seconds, :second)

  defp absolute_grant_expiration(now, refresh_ttl_seconds, %DateTime{} = grant_expires_at) do
    earlier(DateTime.add(now, refresh_ttl_seconds, :second), grant_expires_at)
  end

  defp earlier(left, right) do
    if DateTime.compare(left, right) == :gt, do: right, else: left
  end

  defp parse_redirect_uris(nil), do: []

  defp parse_redirect_uris(value) when is_binary(value) do
    value
    |> String.split(~r/[\s\n]+/, trim: true)
    |> Enum.uniq()
  end

  defp parse_redirect_uris(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_redirect_uris(_), do: []

  defp generate_token(bytes) when is_integer(bytes) and bytes > 0 do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp digest_token(token) when is_binary(token) do
    token = String.trim(token)

    :sha256
    |> :crypto.hash(token)
    |> Base.encode16(case: :lower)
  end
end
