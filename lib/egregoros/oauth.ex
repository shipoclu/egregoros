defmodule Egregoros.OAuth do
  import Ecto.Query, only: [from: 2]

  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.OAuth.AuthorizationCode
  alias Egregoros.OAuth.Scopes
  alias Egregoros.OAuth.Token
  alias Egregoros.Repo
  alias Egregoros.User

  @default_code_ttl_seconds 600
  @default_access_token_ttl_seconds 3_600
  @default_refresh_token_ttl_seconds 31_536_000

  def create_application(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    application_attrs = %{
      name: Map.get(attrs, "client_name") || Map.get(attrs, :client_name) || "App",
      website: Map.get(attrs, "website") || Map.get(attrs, :website),
      redirect_uris:
        parse_redirect_uris(Map.get(attrs, "redirect_uris") || Map.get(attrs, :redirect_uris)),
      scopes: Map.get(attrs, "scopes") || Map.get(attrs, :scopes) || "",
      client_id: generate_token(32),
      client_secret: generate_token(48),
      inserted_at: now,
      updated_at: now
    }

    %OAuthApplication{}
    |> OAuthApplication.changeset(application_attrs)
    |> Repo.insert()
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
    if redirect_uri_allowed?(application, redirect_uri) do
      if Scopes.subset?(scopes, application.scopes) do
        with {:ok, pkce_attrs} <- pkce_attrs(application, opts) do
          ttl_seconds =
            Egregoros.Config.get(:oauth_code_ttl_seconds, @default_code_ttl_seconds)

          expires_at = DateTime.add(DateTime.utc_now(), ttl_seconds, :second)

          attrs =
            Map.merge(pkce_attrs, %{
              code: generate_token(32),
              redirect_uri: redirect_uri,
              scopes: scopes,
              expires_at: expires_at,
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

  def get_authorization_code(nil), do: nil

  def get_authorization_code(code) when is_binary(code) do
    Repo.get_by(AuthorizationCode, code: code)
  end

  def exchange_code_for_token(
        %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client_id,
          "client_secret" => client_secret,
          "redirect_uri" => redirect_uri
        } = params
      )
      when is_binary(code) and is_binary(client_id) and is_binary(client_secret) and
             is_binary(redirect_uri) do
    case get_application_by_client_id(client_id) do
      %OAuthApplication{} = application ->
        if Plug.Crypto.secure_compare(application.client_secret, client_secret) do
          exchange_authorization_code(application, code, redirect_uri, params)
        else
          {:error, :invalid_grant}
        end

      nil ->
        {:error, :invalid_client}
    end
  end

  def exchange_code_for_token(
        %{
          "grant_type" => "refresh_token",
          "refresh_token" => refresh_token,
          "client_id" => client_id,
          "client_secret" => client_secret
        } = params
      )
      when is_binary(refresh_token) and is_binary(client_id) and is_binary(client_secret) do
    refresh_token = String.trim(refresh_token)

    with %OAuthApplication{} = application <- get_application_by_client_id(client_id),
         true <- Plug.Crypto.secure_compare(application.client_secret, client_secret) do
      rotate_refresh_token(application, refresh_token, params)
    else
      nil -> {:error, :invalid_client}
      false -> {:error, :invalid_grant}
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
         true <- Plug.Crypto.secure_compare(application.client_secret, client_secret),
         :ok <- validate_redirect_uri_param(application, params),
         {:ok, scopes} <- client_credentials_scopes(params, application),
         {:ok, %Token{} = token} <- create_token(application, nil, scopes) do
      {:ok, token}
    else
      nil -> {:error, :invalid_client}
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
      preload: [user: u]
    )
    |> Repo.one()
  end

  def revoke_token(%{
        "token" => token,
        "client_id" => client_id,
        "client_secret" => client_secret
      })
      when is_binary(token) and is_binary(client_id) and is_binary(client_secret) do
    token = String.trim(token)

    with %OAuthApplication{} = application <- get_application_by_client_id(client_id),
         true <- Plug.Crypto.secure_compare(application.client_secret, client_secret) do
      _ = revoke_token_record_for_token(application.id, token)
      :ok
    else
      nil -> {:error, :invalid_client}
      false -> {:error, :invalid_client}
      _ -> {:error, :invalid_client}
    end
  end

  def revoke_token(_params), do: {:error, :invalid_request}

  defp create_token(application, user_id, scopes, opts \\ [])

  defp create_token(%OAuthApplication{} = application, user_id, scopes, opts)
       when is_binary(user_id) and is_binary(scopes) and is_list(opts) do
    now = DateTime.utc_now()
    ttl_seconds = access_token_ttl_seconds()
    refresh_ttl_seconds = refresh_token_ttl_seconds()

    expires_at =
      case ttl_seconds do
        seconds when is_integer(seconds) and seconds >= 1 -> DateTime.add(now, seconds, :second)
        _ -> nil
      end

    refresh_expires_at =
      case refresh_ttl_seconds do
        seconds when is_integer(seconds) and seconds >= 1 ->
          DateTime.add(now, seconds, :second)

        _ ->
          nil
      end

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

    expires_at =
      case ttl_seconds do
        seconds when is_integer(seconds) and seconds >= 1 -> DateTime.add(now, seconds, :second)
        _ -> nil
      end

    refresh_expires_at =
      case refresh_ttl_seconds do
        seconds when is_integer(seconds) and seconds >= 1 ->
          DateTime.add(now, seconds, :second)

        _ ->
          nil
      end

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

  defp exchange_authorization_code(application, code, redirect_uri, params) do
    case Repo.transaction(fn ->
           auth_code =
             from(c in AuthorizationCode, where: c.code == ^code, lock: "FOR UPDATE")
             |> Repo.one()

           with %AuthorizationCode{} <- auth_code,
                true <- auth_code.application_id == application.id,
                true <- auth_code.redirect_uri == redirect_uri,
                true <- DateTime.compare(auth_code.expires_at, DateTime.utc_now()) == :gt,
                :ok <- verify_pkce(auth_code, params),
                {:ok, %Token{} = token} <-
                  create_token(application, auth_code.user_id, auth_code.scopes),
                {:ok, _deleted} <- Repo.delete(auth_code) do
             token
           else
             _ -> Repo.rollback(:invalid_grant)
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

  defp rotate_refresh_token(application, refresh_token, params) do
    refresh_digest = digest_token(refresh_token)

    case Repo.transaction(fn ->
           old_token =
             from(t in Token,
               where: t.refresh_token_digest == ^refresh_digest,
               lock: "FOR UPDATE"
             )
             |> Repo.one()

           rotate_locked_refresh_token(old_token, application, params)
         end) do
      {:ok, {:ok, %Token{} = token}} -> {:ok, token}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rotate_locked_refresh_token(nil, _application, _params),
    do: {:error, :invalid_grant}

  defp rotate_locked_refresh_token(
         %Token{application_id: token_application_id},
         %OAuthApplication{id: application_id},
         _params
       )
       when token_application_id != application_id,
       do: {:error, :invalid_grant}

  defp rotate_locked_refresh_token(
         %Token{consumed_at: consumed_at, revoked_at: revoked_at} = token,
         _application,
         _params
       )
       when not is_nil(consumed_at) or not is_nil(revoked_at) do
    _ = revoke_token_family(token)
    {:error, :invalid_grant}
  end

  defp rotate_locked_refresh_token(%Token{} = old_token, application, params) do
    if refresh_token_active?(old_token) do
      with {:ok, scopes} <- refresh_scopes(params, old_token, application),
           {:ok, _consumed} <-
             old_token
             |> Token.changeset(%{
               consumed_at: DateTime.utc_now(),
               revoked_at: DateTime.utc_now()
             })
             |> Repo.update(),
           {:ok, %Token{} = token} <-
             create_token(application, old_token.user_id, scopes, family_id: old_token.family_id) do
        {:ok, token}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      {:error, :invalid_grant}
    end
  end

  defp revoke_token_family(%Token{family_id: family_id}) when is_binary(family_id) do
    from(t in Token, where: t.family_id == ^family_id and is_nil(t.revoked_at))
    |> Repo.update_all(set: [revoked_at: DateTime.utc_now()])

    :ok
  end

  defp revoke_token_family(_token), do: :ok

  defp refresh_token_active?(%Token{refresh_expires_at: nil}), do: true

  defp refresh_token_active?(%Token{refresh_expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  defp refresh_token_active?(_), do: false

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
    Egregoros.Config.get(:oauth_access_token_ttl_seconds, @default_access_token_ttl_seconds)
  end

  defp refresh_token_ttl_seconds do
    Egregoros.Config.get(:oauth_refresh_token_ttl_seconds, @default_refresh_token_ttl_seconds)
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
