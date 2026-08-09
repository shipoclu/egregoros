defmodule EgregorosWeb.OAuthServerMetadataController do
  use EgregorosWeb, :controller

  alias EgregorosWeb.Endpoint

  def show(conn, _params) do
    issuer = Endpoint.url()

    json(conn, %{
      "issuer" => issuer,
      "authorization_endpoint" => issuer <> "/oauth/authorize",
      "token_endpoint" => issuer <> "/oauth/token",
      "revocation_endpoint" => issuer <> "/oauth/revoke",
      "registration_endpoint" => issuer <> "/oauth/mini-app/register",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["client_secret_post", "none"],
      "scopes_supported" => ["identify", "profile", "read", "write", "follow", "push"],
      "fediverse_miniapp_profile" => "1",
      "fediverse_miniapp_session_restore_endpoint" =>
        issuer <> "/api/v1/mini-apps/session-restores/consume"
    })
  end
end
