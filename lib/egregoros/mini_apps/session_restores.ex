defmodule Egregoros.MiniApps.SessionRestores do
  @moduledoc false

  import Ecto.Query

  alias Egregoros.MiniApps
  alias Egregoros.MiniApps.OAuthRegistration
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.MiniApps.SessionRestore
  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.OAuth.Scopes
  alias Egregoros.OAuth.Token
  alias Egregoros.Repo
  alias Egregoros.User
  alias EgregorosWeb.Endpoint
  alias EgregorosWeb.ProfilePaths
  alias EgregorosWeb.URL

  @restore_ttl_seconds 60
  @encoded_value ~r/^[A-Za-z0-9_-]+$/

  def issue(%User{} = user, app_origin, client_id, restore_challenge) do
    with :ok <- validate_origin(app_origin),
         :ok <- validate_client_id(client_id),
         :ok <- validate_challenge(restore_challenge),
         %OAuthRegistration{} = registration <- OAuthRegistrations.get_by_origin(app_origin),
         %OAuthApplication{client_id: ^client_id} = application <-
           Repo.get(OAuthApplication, registration.oauth_application_id),
         true <- OAuthRegistrations.application_allowed?(application),
         true <- active_scope?(user.id, application.id, "identify") do
      code = random_value()

      attrs = %{
        code_digest: digest(code),
        restore_challenge: restore_challenge,
        app_origin: app_origin,
        expires_at: DateTime.add(DateTime.utc_now(), @restore_ttl_seconds, :second),
        user_id: user.id,
        oauth_application_id: application.id
      }

      restore = %SessionRestore{
        user_id: user.id,
        oauth_application_id: application.id
      }

      case restore |> SessionRestore.changeset(attrs) |> Repo.insert() do
        {:ok, _restore} -> {:ok, code}
        {:error, _changeset} -> {:error, :interaction_required}
      end
    else
      _other -> {:error, :interaction_required}
    end
  rescue
    ArgumentError -> {:error, :interaction_required}
    Ecto.Query.CastError -> {:error, :interaction_required}
  end

  def issue(_user, _app_origin, _client_id, _restore_challenge),
    do: {:error, :interaction_required}

  def consume(restore_code, restore_verifier) do
    with :ok <- validate_code(restore_code),
         :ok <- validate_verifier(restore_verifier),
         {:ok, claims} <-
           Repo.transaction(fn -> consume_locked(restore_code, restore_verifier) end) do
      {:ok, claims}
    else
      _other -> {:error, :invalid_restore}
    end
  rescue
    ArgumentError -> {:error, :invalid_restore}
    Ecto.Query.CastError -> {:error, :invalid_restore}
  end

  defp consume_locked(restore_code, restore_verifier) do
    now = DateTime.utc_now()

    restore =
      from(restore in SessionRestore,
        where:
          restore.code_digest == ^digest(restore_code) and is_nil(restore.consumed_at) and
            restore.expires_at > ^now,
        lock: "FOR UPDATE",
        preload: [:user, :oauth_application]
      )
      |> Repo.one()

    with %SessionRestore{} = restore <- restore,
         true <- secure_equal?(challenge(restore_verifier), restore.restore_challenge),
         %OAuthRegistration{} = registration <-
           OAuthRegistrations.get_by_application_id(restore.oauth_application_id),
         true <- registration.app_origin == restore.app_origin,
         true <- origin_allowed?(restore.app_origin),
         true <- OAuthRegistrations.application_allowed?(restore.oauth_application),
         true <- active_scope?(restore.user_id, restore.oauth_application_id, "identify"),
         {:ok, consumed} <-
           restore
           |> Ecto.Changeset.change(consumed_at: now)
           |> Repo.update() do
      identity_claims(consumed.user, restore.oauth_application_id)
    else
      _other -> Repo.rollback(:invalid_restore)
    end
  end

  defp identity_claims(user, application_id) do
    host = URI.parse(Endpoint.url()).host

    %{
      issuer: Endpoint.url(),
      sub: user.ap_id,
      acct: "#{user.nickname}@#{host}"
    }
    |> maybe_add_profile(user, active_scope?(user.id, application_id, "profile"))
  end

  defp maybe_add_profile(identity, user, true) do
    identity
    |> Map.merge(%{
      preferred_username: user.nickname,
      name: user.name || user.nickname,
      profile: URL.absolute(ProfilePaths.profile_path(user))
    })
    |> maybe_put_picture(URL.absolute(user.avatar_url, user.ap_id))
  end

  defp maybe_add_profile(identity, _user, false), do: identity

  defp maybe_put_picture(identity, picture) when is_binary(picture) and picture != "",
    do: Map.put(identity, :picture, picture)

  defp maybe_put_picture(identity, _picture), do: identity

  defp active_scope?(user_id, application_id, required_scope) do
    now = DateTime.utc_now()

    from(token in Token,
      where:
        token.user_id == ^user_id and token.application_id == ^application_id and
          is_nil(token.revoked_at) and
          (is_nil(token.refresh_expires_at) or token.refresh_expires_at > ^now),
      select: token.scopes
    )
    |> Repo.all()
    |> Enum.any?(&Scopes.contains_all?(&1, [required_scope]))
  end

  defp origin_allowed?(origin) do
    case URI.parse(origin) do
      %URI{scheme: "https", host: host, userinfo: nil, path: path, query: nil, fragment: nil}
      when is_binary(host) and host != "" and path in [nil, ""] ->
        MiniApps.domain_allowed?(host)

      %URI{scheme: "http", host: host, userinfo: nil, path: path, query: nil, fragment: nil}
      when host in ["localhost", "127.0.0.1", "::1"] and path in [nil, ""] ->
        MiniApps.domain_allowed?(host)

      _other ->
        false
    end
  end

  defp validate_origin(origin) when is_binary(origin) do
    if byte_size(origin) <= 2_048 and origin_allowed?(origin), do: :ok, else: :error
  end

  defp validate_origin(_origin), do: :error

  defp validate_client_id(client_id) when is_binary(client_id) do
    if byte_size(client_id) in 10..200 and Regex.match?(@encoded_value, client_id),
      do: :ok,
      else: :error
  end

  defp validate_client_id(_client_id), do: :error

  defp validate_challenge(value) when is_binary(value) do
    if byte_size(value) == 43 and Regex.match?(@encoded_value, value), do: :ok, else: :error
  end

  defp validate_challenge(_value), do: :error

  defp validate_code(value) when is_binary(value) do
    if byte_size(value) in 16..512 and Regex.match?(@encoded_value, value), do: :ok, else: :error
  end

  defp validate_code(_value), do: :error

  defp validate_verifier(value) when is_binary(value) do
    if byte_size(value) in 43..512 and Regex.match?(@encoded_value, value), do: :ok, else: :error
  end

  defp validate_verifier(_value), do: :error

  defp challenge(value), do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp random_value, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false
end
