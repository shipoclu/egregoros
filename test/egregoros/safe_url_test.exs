defmodule Egregoros.SafeURLTest do
  use ExUnit.Case, async: true

  import Mox

  alias Egregoros.SafeURL

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(Egregoros.DNS.Mock, :lookup_ips, fn _host ->
      {:ok, [{1, 1, 1, 1}]}
    end)

    :ok
  end

  test "allows https urls" do
    assert :ok == SafeURL.validate_http_url("https://remote.example/users/alice")
  end

  test "mini-app resolution requires an https domain and pins its public address" do
    expect(Egregoros.DNS.Mock, :lookup_ips, fn "app.example" ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    assert {:ok, resolved} =
             SafeURL.resolve_https_domain_url("https://app.example:8443/path?x=1")

    assert resolved.hostname == "app.example"
    assert resolved.ip == {93, 184, 216, 34}
    assert resolved.connect_url == "https://93.184.216.34:8443/path?x=1"
    assert resolved.authority == "app.example:8443"
    assert resolved.canonical_url == "https://app.example:8443/path?x=1"

    for url <- [
          "http://app.example/path",
          "https://127.0.0.1/path",
          "https://93.184.216.34/path",
          "https://127.0x0.1/path",
          "https://127.0.0x0.1/path",
          "https://app.example/path#fragment",
          "https://user@app.example/path",
          "https://@app.example/path"
        ] do
      assert {:error, :unsafe_url} = SafeURL.resolve_https_domain_url(url)
    end
  end

  test "exported URL resolution rejects parser-differential byte sequences" do
    for suffix <- [
          "/raw\r\nheader:value",
          "/raw\0value",
          "/raw\tvalue",
          "/has space",
          "/back\\slash",
          "/bare%",
          "/short%0",
          "/invalid%zz",
          "/encoded%00nul",
          "/encoded%0dreturn",
          "/encoded%0Alinefeed",
          "/encoded%7fdelete",
          "/encoded%5cbackslash"
        ] do
      assert {:error, :unsafe_url} =
               SafeURL.resolve_https_domain_url("https://app.example" <> suffix)
    end

    assert {:error, :unsafe_url} = SafeURL.resolve_https_domain_url("//app.example/path")
  end

  test "mini-app resolution rejects a domain when any dns answer is not global" do
    expect(Egregoros.DNS.Mock, :lookup_ips, fn "rebind.example" ->
      {:ok, [{93, 184, 216, 34}, {127, 0, 0, 1}]}
    end)

    assert {:error, :unsafe_url} =
             SafeURL.resolve_https_domain_url("https://rebind.example/manifest")
  end

  test "allows http urls" do
    assert :ok == SafeURL.validate_http_url("http://remote.example/users/alice")
  end

  test "rejects non-http schemes" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("file:///etc/passwd")
  end

  test "rejects urls without a host" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("https:///users/alice")
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("https://")
  end

  test "rejects non-binary urls" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url(nil)
    assert {:error, :unsafe_url} == SafeURL.validate_http_url(123)
  end

  test "rejects localhost" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("http://localhost/users/alice")
  end

  test "rejects loopback ip literals" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("http://127.0.0.1/users/alice")
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("http://[::1]/users/alice")

    for host <- ["0177.0.0.1", "127.0x0.1", "127.0.0x0.1", "017700000001"] do
      assert {:error, :unsafe_url} ==
               SafeURL.validate_http_url("http://#{host}/users/alice")
    end
  end

  test "rejects IPv4-embedded IPv6 loopback/private literals" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("http://[::127.0.0.1]/users/alice")

    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url("http://[::ffff:127.0.0.1]/users/alice")

    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url("http://[::ffff:10.0.0.1]/users/alice")

    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url("http://[::ffff:8.8.8.8]/users/alice")
  end

  test "rejects private ip literals" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("http://10.0.0.1/users/alice")
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("http://192.168.0.1/users/alice")
  end

  test "rejects URL userinfo and non-global special-use addresses" do
    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url("https://user:password@remote.example/private")

    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url("https://@remote.example/private")

    for url <- [
          "http://192.0.2.1/object",
          "http://198.51.100.1/object",
          "http://203.0.113.1/object",
          "http://224.0.0.1/object",
          "http://240.0.0.1/object",
          "http://[2001:db8::1]/object",
          "http://[ff02::1]/object",
          "http://[::ffff:8.8.8.8]/object"
        ] do
      assert {:error, :unsafe_url} == SafeURL.validate_http_url(url)
    end
  end

  test "rejects non-global IANA special-purpose DNS answers" do
    for {hostname, ip} <- [
          {"deprecated-6to4.example", {192, 88, 99, 1}},
          {"documentation-v4.example", {192, 0, 2, 1}},
          {"benchmark.example", {198, 18, 0, 1}},
          {"documentation-v6.example", {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}}
        ] do
      expect(Egregoros.DNS.Mock, :lookup_ips, fn ^hostname -> {:ok, [ip]} end)

      assert {:error, :unsafe_url} ==
               SafeURL.validate_http_url("https://#{hostname}/object")
    end
  end

  test "resolves once and returns a connection URL pinned to the validated address" do
    expect(Egregoros.DNS.Mock, :lookup_ips, fn "pinned.example" ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    assert {:ok, resolved} =
             SafeURL.resolve_http_url_federation("https://pinned.example:8443/objects/1?x=1")

    assert resolved.hostname == "pinned.example"
    assert resolved.ip == {93, 184, 216, 34}
    assert resolved.connect_url == "https://93.184.216.34:8443/objects/1?x=1"
  end

  test "rejects invalid ip literals" do
    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url("http://999.999.999.999/users/alice")
  end

  test "rejects private ipv6 literals" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("http://[fc00::1]/users/alice")
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("http://[fe80::1]/users/alice")
  end

  test "allows public ipv6 literals" do
    assert :ok == SafeURL.validate_http_url("http://[2001:4860:4860::8888]/users/alice")
  end

  test "rejects IPv6 transition and special-purpose ranges" do
    for url <- [
          "http://[2001::1]/object",
          "http://[2001:20::1]/object",
          "http://[2002:0a00:0001::1]/object",
          "http://[3f00::1]/object",
          "http://[3ffe::1]/object",
          "http://[3fff::1]/object"
        ] do
      assert {:error, :unsafe_url} == SafeURL.validate_http_url(url)
    end
  end

  test "rejects hostnames that resolve to private ips" do
    Egregoros.DNS.Mock
    |> expect(:lookup_ips, fn "private.example" ->
      {:ok, [{127, 0, 0, 1}]}
    end)

    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url("https://private.example/users/alice")
  end

  test "rejects hostnames with no public IPs" do
    Egregoros.DNS.Mock
    |> expect(:lookup_ips, fn "empty.example" -> {:ok, []} end)

    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url("https://empty.example/users/alice")

    Egregoros.DNS.Mock
    |> expect(:lookup_ips, fn "missing.example" -> {:error, :nxdomain} end)

    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url("https://missing.example/users/alice")
  end

  test "validate_http_url_no_dns allows hostnames without DNS lookups" do
    Egregoros.DNS.Mock
    |> expect(:lookup_ips, 0, fn _host -> {:ok, [{127, 0, 0, 1}]} end)

    assert :ok == SafeURL.validate_http_url_no_dns("https://remote.example/users/alice")
  end

  test "validate_http_url_no_dns rejects localhost and private ip literals" do
    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url_no_dns("http://localhost/users/alice")

    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url_no_dns("http://127.0.0.1/users/alice")

    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url_no_dns("http://10.0.0.1/users/alice")

    assert {:error, :unsafe_url} == SafeURL.validate_http_url_no_dns("http://[::1]/users/alice")
  end

  test "validate_http_url_no_dns rejects non-http schemes" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url_no_dns("file:///etc/passwd")
  end

  test "validate_http_url_no_dns rejects urls without a host" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url_no_dns("https:///users/alice")
    assert {:error, :unsafe_url} == SafeURL.validate_http_url_no_dns("https://")
  end

  test "validate_http_url_no_dns rejects non-binary urls" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url_no_dns(nil)
    assert {:error, :unsafe_url} == SafeURL.validate_http_url_no_dns(123)
  end

  test "validate_http_url_no_dns allows public ip literals" do
    assert :ok == SafeURL.validate_http_url_no_dns("http://8.8.8.8/users/alice")
    assert :ok == SafeURL.validate_http_url_no_dns("http://[2001:4860:4860::8888]/users/alice")
  end

  test "validate_http_url_no_dns allows obfuscated public IPv4 forms" do
    assert :ok == SafeURL.validate_http_url_no_dns("http://134744072/users/alice")
    assert :ok == SafeURL.validate_http_url_no_dns("http://0x08080808/users/alice")
    assert :ok == SafeURL.validate_http_url_no_dns("http://8.8/users/alice")
    assert :ok == SafeURL.validate_http_url_no_dns("http://8.8.8/users/alice")
    assert :ok == SafeURL.validate_http_url_no_dns("http://0x8.0x8.0x8.0x8/users/alice")
    assert :ok == SafeURL.validate_http_url_no_dns("http://010.010.010.010/users/alice")
  end

  test "validate_http_url_no_dns follows browser octal semantics for legacy IPv4" do
    for host <- ["0177.0.0.1", "0177.0x0.0.1", "017700000001"] do
      assert {:error, :unsafe_url} ==
               SafeURL.validate_http_url_no_dns("http://#{host}/users/alice")
    end

    # WHATWG treats a numeric final label as an IPv4 candidate, then rejects
    # invalid octal rather than falling back to a hostname.
    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url_no_dns("http://010.010.010.08/users/alice")
  end

  test "validate_http_url_no_dns rejects numeric hosts that fail parsing" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url_no_dns("http://0x/users/alice")
    assert {:error, :unsafe_url} == SafeURL.validate_http_url_no_dns("http://0xGG/users/alice")

    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url_no_dns("http://4294967296/users/alice")

    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url_no_dns("http://0x100.0.0.1/users/alice")

    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url_no_dns("http://8.16777216/users/alice")

    assert {:error, :unsafe_url} ==
             SafeURL.validate_http_url_no_dns("http://8.8.65536/users/alice")
  end

  test "validate_http_url_federation allows private federation hostnames when configured" do
    Egregoros.DNS.Mock
    |> expect(:lookup_ips, 0, fn _host ->
      flunk("unexpected DNS lookup for federation-safe URL validation")
    end)

    stub(Egregoros.Config.Mock, :get, fn
      :allow_private_federation, _default -> true
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      assert :ok == SafeURL.validate_http_url_federation("https://private.example/users/alice")
    end)
  end

  test "validate_http_url_federation treats allow_private_federation=1 as enabled" do
    Egregoros.DNS.Mock
    |> expect(:lookup_ips, 0, fn _host ->
      flunk("unexpected DNS lookup for federation-safe URL validation")
    end)

    stub(Egregoros.Config.Mock, :get, fn
      :allow_private_federation, _default -> "1"
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      assert :ok == SafeURL.validate_http_url_federation("https://private.example/users/alice")
    end)
  end
end
