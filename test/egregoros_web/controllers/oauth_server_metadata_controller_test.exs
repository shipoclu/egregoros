defmodule EgregorosWeb.OAuthServerMetadataControllerTest do
  use EgregorosWeb.ConnCase, async: true

  alias EgregorosWeb.Endpoint

  test "GET /.well-known/oauth-authorization-server advertises the mini-app profile", %{
    conn: conn
  } do
    conn =
      conn
      |> put_req_header("origin", "https://app.example")
      |> get("/.well-known/oauth-authorization-server")

    metadata = json_response(conn, 200)
    issuer = Endpoint.url()

    assert metadata["issuer"] == issuer
    assert metadata["authorization_endpoint"] == issuer <> "/oauth/authorize"
    assert metadata["token_endpoint"] == issuer <> "/oauth/token"
    assert metadata["revocation_endpoint"] == issuer <> "/oauth/revoke"
    assert metadata["registration_endpoint"] == issuer <> "/oauth/mini-app/register"
    assert metadata["response_types_supported"] == ["code"]
    assert metadata["grant_types_supported"] == ["authorization_code", "refresh_token"]
    assert metadata["code_challenge_methods_supported"] == ["S256"]
    assert metadata["token_endpoint_auth_methods_supported"] == ["client_secret_post", "none"]
    assert metadata["scopes_supported"] == ["identify", "read", "write", "follow", "push"]
    assert metadata["fediverse_miniapp_profile"] == "1"
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end
end
