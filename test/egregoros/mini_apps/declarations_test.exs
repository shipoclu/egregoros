defmodule Egregoros.MiniApps.DeclarationsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.Manifest

  setup do
    allow_mini_apps([])
    :ok
  end

  test "pins one immutable security declaration per exact app origin" do
    manifest = manifest_fixture()

    assert {:ok, first, :created} = Declarations.ensure(manifest)
    assert {:ok, second, :existing} = Declarations.ensure(manifest)

    assert first.id == second.id
    assert first.app_origin == "https://wallet.example"
    assert first.capabilities == []
    assert first.oauth_redirect_uris == []
    assert first.oauth_scopes == []
    assert first.wallet_evm_enabled
    refute first.wallet_evm_required
    assert first.wallet_evm_required_chains == ["eip155:8453"]
    assert Declarations.get_by_origin("https://wallet.example").id == first.id
  end

  test "rejects later wallet, OAuth, or capability mutations" do
    assert {:ok, _declaration, :created} = Declarations.ensure(manifest_fixture())

    refute_manifest_change(%{"required" => true})
    refute_manifest_change(%{"requiredChains" => ["eip155:1"]})
    refute_manifest_change(%{"enabled" => false, "requiredChains" => []})

    changed_oauth = manifest_fixture(oauth?: true)
    assert {:error, :manifest_changed} = Declarations.ensure(changed_oauth)

    changed_capabilities = %{changed_oauth | capabilities: ["compose_note"]}
    assert {:error, :manifest_changed} = Declarations.ensure(changed_capabilities)
  end

  test "rechecks current operator policy" do
    allow_mini_apps(["wallet.example"])
    assert {:error, :domain_denied} = Declarations.ensure(manifest_fixture())
    assert Declarations.get_by_origin("https://wallet.example") == nil
  end

  defp refute_manifest_change(wallet_overrides) do
    wallet =
      %{
        "enabled" => true,
        "required" => false,
        "requiredChains" => ["eip155:8453"]
      }
      |> Map.merge(wallet_overrides)

    assert {:error, :manifest_changed} =
             wallet
             |> manifest_fixture()
             |> Declarations.ensure()
  end

  defp manifest_fixture(options \\ [])

  defp manifest_fixture(options) when is_list(options) do
    oauth? = Keyword.get(options, :oauth?, false)

    attrs = %{
      "version" => "1",
      "name" => "Wallet App",
      "homeUrl" => "https://wallet.example/",
      "wallet" => %{
        "evm" => %{
          "enabled" => true,
          "required" => false,
          "requiredChains" => ["eip155:8453"]
        }
      },
      "capabilities" => []
    }

    attrs =
      if oauth? do
        Map.put(attrs, "oauth", %{
          "redirectUris" => ["https://wallet.example/oauth/callback"],
          "scopes" => ["read", "write"]
        })
      else
        attrs
      end

    decode_manifest(attrs)
  end

  defp manifest_fixture(wallet) when is_map(wallet) do
    decode_manifest(%{
      "version" => "1",
      "name" => "Wallet App",
      "homeUrl" => "https://wallet.example/",
      "wallet" => %{"evm" => wallet},
      "capabilities" => []
    })
  end

  defp decode_manifest(attrs) do
    assert {:ok, manifest} =
             Manifest.decode(
               Jason.encode!(attrs),
               "https://wallet.example/.well-known/fediverse-miniapp.json"
             )

    manifest
  end

  defp allow_mini_apps(denylist) do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> denylist
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)
  end
end
