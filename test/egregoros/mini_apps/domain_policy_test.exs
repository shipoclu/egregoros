defmodule Egregoros.MiniApps.DomainPolicyTest do
  use ExUnit.Case, async: true

  alias Egregoros.MiniApps.DomainPolicy

  test "allows every valid domain when both lists are empty" do
    assert DomainPolicy.allowed?("app.example", allow: [], deny: [])
  end

  test "exact patterns match only the exact domain" do
    assert DomainPolicy.allowed?("app.example", allow: ["app.example"], deny: [])
    refute DomainPolicy.allowed?("child.app.example", allow: ["app.example"], deny: [])
  end

  test "wildcards match subdomains but not their apex" do
    assert DomainPolicy.allowed?("one.apps.example", allow: ["*.apps.example"], deny: [])
    assert DomainPolicy.allowed?("deep.one.apps.example", allow: ["*.apps.example"], deny: [])
    refute DomainPolicy.allowed?("apps.example", allow: ["*.apps.example"], deny: [])
    refute DomainPolicy.allowed?("notapps.example", allow: ["*.apps.example"], deny: [])
  end

  test "deny rules win over allow rules" do
    refute DomainPolicy.allowed?("blocked.apps.example",
             allow: ["*.apps.example"],
             deny: ["blocked.apps.example"]
           )
  end

  test "a non-empty allowlist is restrictive" do
    refute DomainPolicy.allowed?("other.example", allow: ["app.example"], deny: [])
  end

  test "matching is case-insensitive and canonicalizes a final dot" do
    assert DomainPolicy.allowed?("App.Example.", allow: ["app.example"], deny: [])
  end

  test "rejects malformed domains and patterns" do
    for domain <- ["", "https://app.example", "app..example", "*.app.example", "127.0.0.1"] do
      refute DomainPolicy.allowed?(domain, allow: [], deny: [])
    end

    assert {:error, :invalid_domain_pattern} =
             DomainPolicy.validate_patterns(["https://app.example"])

    assert {:error, :invalid_domain_pattern} = DomainPolicy.validate_patterns(["*example.com"])
    assert :ok = DomainPolicy.validate_patterns(["example.com", "*.example.com"])
  end
end
