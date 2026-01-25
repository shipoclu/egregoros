defmodule Egregoros.Mentions.DomainTest do
  use ExUnit.Case, async: true

  alias Egregoros.Mentions.Domain

  test "normalize_host/1 trims and downcases" do
    assert Domain.normalize_host(" Example.COM ") == "example.com"
    assert Domain.normalize_host(nil) == nil
    assert Domain.normalize_host(123) == nil
  end

  test "local_domains/1 returns host and host:port when port is present" do
    assert Domain.local_domains("https://example.com:443/users/alice") == [
             "example.com",
             "example.com:443"
           ]
  end

  test "local_domains/1 includes the scheme default port for http/https URIs" do
    assert Domain.local_domains("https://example.com/users/alice") == [
             "example.com",
             "example.com:443"
           ]

    assert Domain.local_domains("http://example.com/users/alice") == [
             "example.com",
             "example.com:80"
           ]
  end

  test "local_domains/1 returns [] for invalid input" do
    assert Domain.local_domains(nil) == []
    assert Domain.local_domains("not a url") == []
  end
end
