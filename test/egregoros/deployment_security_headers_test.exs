defmodule Egregoros.DeploymentSecurityHeadersTest do
  use ExUnit.Case, async: true

  @caddyfile "docker/caddy/Caddyfile"
  @nginx_config "deploy/nginx/egregoros.conf"

  test "standalone Caddy applies transport security headers to every public origin" do
    caddyfile = File.read!(@caddyfile)

    assert caddyfile =~ "(security_headers)"
    assert caddyfile =~ ~s(Strict-Transport-Security "max-age=31536000; includeSubDomains")
    assert caddyfile =~ ~s(X-Content-Type-Options "nosniff")
    assert caddyfile =~ ~s(Referrer-Policy "strict-origin-when-cross-origin")
    assert caddyfile =~ "Permissions-Policy"

    assert Regex.scan(~r/import security_headers/, caddyfile) |> length() == 4
  end

  test "standalone Caddy preserves Egregoros' route-specific CSP" do
    caddyfile = File.read!(@caddyfile)

    refute caddyfile =~ "Content-Security-Policy"
    refute caddyfile =~ "X-Frame-Options"
  end

  test "sample nginx proxy preserves the mini-app security boundary" do
    config = File.read!(@nginx_config)

    assert config =~ "server_name social.example;"
    assert config =~ "server_name media.social.example;"
    assert config =~ "proxy_set_header X-Forwarded-Proto https;"
    assert config =~ "proxy_set_header Upgrade $http_upgrade;"
    assert config =~ "proxy_set_header Connection $connection_upgrade;"
    assert config =~ "proxy_buffering off;"
    assert config =~ "proxy_cache off;"
    assert config =~ "location ^~ /uploads/"
    assert config =~ "return 404;"

    refute config =~ "add_header Content-Security-Policy"
    refute config =~ "proxy_hide_header Content-Security-Policy"
    refute config =~ "add_header X-Frame-Options"
  end
end
