defmodule Egregoros.MiniApps.WalletConnectionsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.WalletConnections
  alias Egregoros.Users

  setup do
    allow_mini_apps([])
    {:ok, user} = Users.create_local_user("wallet-connection-user")
    {:ok, _declaration, :created} = Declarations.ensure(wallet_manifest())
    %{user: user}
  end

  test "remembers normalized public accounts for one user and exact app origin", %{user: user} do
    assert {:ok, connection} =
             WalletConnections.connect(user.id, "https://wallet.example", [
               "0x1111111111111111111111111111111111111111",
               "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
               "0x1111111111111111111111111111111111111111"
             ])

    assert connection.accounts == [
             "0x1111111111111111111111111111111111111111",
             "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
           ]

    assert WalletConnections.accounts(user.id, "https://wallet.example") == connection.accounts
    assert WalletConnections.connected?(user.id, "https://wallet.example")
    assert WalletConnections.list_for_user(user.id) == [connection]

    {:ok, other_user} = Users.create_local_user("other-wallet-user")
    assert WalletConnections.accounts(other_user.id, "https://wallet.example") == []
  end

  test "rejects invalid accounts and apps without a current wallet declaration", %{user: user} do
    assert {:error, :invalid_accounts} =
             WalletConnections.connect(user.id, "https://wallet.example", [])

    assert {:error, :invalid_accounts} =
             WalletConnections.connect(user.id, "https://wallet.example", ["0x1234"])

    assert {:error, :wallet_not_declared} =
             WalletConnections.connect(user.id, "https://other.example", [
               "0x1111111111111111111111111111111111111111"
             ])
  end

  test "policy changes hide account access immediately but do not prevent revocation", %{
    user: user
  } do
    assert {:ok, _connection} =
             WalletConnections.connect(user.id, "https://wallet.example", [
               "0x1111111111111111111111111111111111111111"
             ])

    allow_mini_apps(["wallet.example"])
    assert WalletConnections.accounts(user.id, "https://wallet.example") == []
    refute WalletConnections.connected?(user.id, "https://wallet.example")
    assert [_connection] = WalletConnections.list_for_user(user.id)

    assert :ok = WalletConnections.revoke(user.id, "https://wallet.example")
    assert WalletConnections.list_for_user(user.id) == []
  end

  defp wallet_manifest do
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
