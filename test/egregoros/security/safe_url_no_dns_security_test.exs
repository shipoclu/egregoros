defmodule Egregoros.Security.SafeURLNoDNSSecurityTest do
  use ExUnit.Case, async: true

  @moduletag :security

  alias Egregoros.SafeURL
  alias EgregorosWeb.SafeMediaURL

  describe "SafeURL.validate_http_url_no_dns/1 (client-side SSRF hardening)" do
    test "rejects obfuscated private IP hosts" do
      Enum.each(
        [
          # Common short/obfuscated IPv4 formats that some clients interpret as localhost.
          "http://127.1/evil.png",
          "http://2130706433/evil.png",
          "http://0x7f000001/evil.png",
          "http://0x0a000001/evil.png"
        ],
        fn url ->
          assert SafeURL.validate_http_url_no_dns(url) == {:error, :unsafe_url}
        end
      )
    end
  end

  describe "SafeMediaURL.safe/1 (client-side SSRF hardening)" do
    test "rejects obfuscated private IP hosts" do
      Enum.each(
        [
          "http://127.1/evil.png",
          "http://2130706433/evil.png",
          "http://0x7f000001/evil.png",
          "http://0x0a000001/evil.png"
        ],
        fn url ->
          assert SafeMediaURL.safe(url) == nil
        end
      )
    end
  end
end
