defmodule Egregoros.MiniApps.ManifestTest do
  use ExUnit.Case, async: true

  alias Egregoros.MiniApps.Manifest

  @manifest_url "https://app.example/.well-known/fediverse-miniapp.json"

  test "decodes a strict valid manifest" do
    assert {:ok, manifest} = Manifest.decode(valid_json(), @manifest_url)

    assert manifest.version == "1"
    assert manifest.name == "Budget Polls"
    assert manifest.origin == "https://app.example"
    assert manifest.home_url == "https://app.example/"
    assert manifest.oauth.scopes == ["read", "write"]
    assert manifest.wallet.evm.enabled
    refute manifest.wallet.evm.required
    assert manifest.wallet.evm.required_chains == ["eip155:8453"]
    assert manifest.capabilities == ["compose_note"]
    assert manifest.cache_ttl_seconds == 600
  end

  test "allows a public app without oauth" do
    json =
      Jason.encode!(%{
        "version" => "1",
        "name" => "Reader",
        "homeUrl" => "https://app.example/reader",
        "capabilities" => []
      })

    assert {:ok, manifest} = Manifest.decode(json, @manifest_url)
    assert manifest.oauth == nil
  end

  test "rejects duplicate json keys at every depth" do
    duplicate_top =
      ~s|{"version":"1","version":"1","name":"Reader","homeUrl":"https://app.example/","capabilities":[]}|

    duplicate_nested =
      ~s|{"version":"1","name":"Reader","homeUrl":"https://app.example/","oauth":{"redirectUris":["https://app.example/cb"],"scopes":["read"],"scopes":["read"]},"capabilities":[]}|

    assert {:error, :duplicate_json_key} = Manifest.decode(duplicate_top, @manifest_url)
    assert {:error, :duplicate_json_key} = Manifest.decode(duplicate_nested, @manifest_url)
  end

  test "rejects unknown fields instead of interpreting them loosely" do
    json = valid_manifest() |> Map.put("unexpected", true) |> Jason.encode!()
    assert {:error, :unknown_field} = Manifest.decode(json, @manifest_url)

    json =
      valid_manifest()
      |> put_in(["oauth", "unexpected"], true)
      |> Jason.encode!()

    assert {:error, :unknown_field} = Manifest.decode(json, @manifest_url)
  end

  test "rejects manifests from the wrong well-known location" do
    assert {:error, :invalid_manifest_url} =
             Manifest.decode(valid_json(), "https://app.example/manifest.json")
  end

  test "rejects cross-origin urls" do
    for {path, value} <- [
          {["homeUrl"], "https://evil.example/"},
          {["iconUrl"], "https://cdn.example/icon.png"},
          {["splash", "imageUrl"], "https://cdn.example/splash.png"},
          {["oauth", "redirectUris"], ["https://api.app.example/callback"]}
        ] do
      json = valid_manifest() |> put_in(path, value) |> Jason.encode!()
      assert {:error, :origin_mismatch} = Manifest.decode(json, @manifest_url)
    end
  end

  test "requires read whenever oauth is declared" do
    json = valid_manifest() |> put_in(["oauth", "scopes"], ["write"]) |> Jason.encode!()
    assert {:error, :read_scope_required} = Manifest.decode(json, @manifest_url)
  end

  test "rejects duplicate scopes, capabilities, redirects, and chains" do
    cases = [
      put_in(valid_manifest(), ["oauth", "scopes"], ["read", "read"]),
      Map.put(valid_manifest(), "capabilities", ["compose_note", "compose_note"]),
      put_in(valid_manifest(), ["oauth", "redirectUris"], [
        "https://app.example/callback",
        "https://app.example/callback"
      ]),
      put_in(valid_manifest(), ["wallet", "evm", "requiredChains"], [
        "eip155:8453",
        "eip155:8453"
      ])
    ]

    for manifest <- cases do
      assert {:error, :duplicate_value} = Manifest.decode(Jason.encode!(manifest), @manifest_url)
    end
  end

  test "rejects unsupported capabilities and malformed chains" do
    json = valid_manifest() |> Map.put("capabilities", ["admin_everything"]) |> Jason.encode!()
    assert {:error, :unsupported_capability} = Manifest.decode(json, @manifest_url)

    json =
      valid_manifest()
      |> put_in(["wallet", "evm", "requiredChains"], ["ethereum:base"])
      |> Jason.encode!()

    assert {:error, :invalid_chain} = Manifest.decode(json, @manifest_url)
  end

  test "bounds document size and cache ttl" do
    assert {:error, :manifest_too_large} =
             Manifest.decode(String.duplicate(" ", 65_537), @manifest_url)

    for ttl <- [0, 59, 3601, 1.5, "60"] do
      json = valid_manifest() |> Map.put("cacheTtlSeconds", ttl) |> Jason.encode!()
      assert {:error, :invalid_cache_ttl} = Manifest.decode(json, @manifest_url)
    end
  end

  defp valid_json, do: Jason.encode!(valid_manifest())

  defp valid_manifest do
    %{
      "version" => "1",
      "name" => "Budget Polls",
      "publisher" => %{
        "name" => "Example Studio",
        "url" => "https://app.example/about"
      },
      "homeUrl" => "https://app.example/",
      "iconUrl" => "https://app.example/icon.png",
      "splash" => %{
        "imageUrl" => "https://app.example/splash.png",
        "backgroundColor" => "#152238"
      },
      "oauth" => %{
        "redirectUris" => ["https://app.example/oauth/callback"],
        "scopes" => ["read", "write"]
      },
      "wallet" => %{
        "evm" => %{
          "enabled" => true,
          "required" => false,
          "requiredChains" => ["eip155:8453"]
        }
      },
      "capabilities" => ["compose_note"],
      "cacheTtlSeconds" => 600
    }
  end
end
