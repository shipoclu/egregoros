defmodule Egregoros.DeploymentSecurityHeadersTest do
  use ExUnit.Case, async: true

  @caddyfile "docker/caddy/Caddyfile"

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
end
