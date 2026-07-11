defmodule Egregoros.MiniApps.WalletRequestTest do
  use ExUnit.Case, async: true

  alias Egregoros.MiniApps.WalletRequest

  @account "0x1111111111111111111111111111111111111111"
  @recipient "0x2222222222222222222222222222222222222222"

  test "validates and summarizes personal signatures for an approved account" do
    assert {:ok, request} =
             WalletRequest.validate("personal_sign", ["0x68656c6c6f", @account], [@account])

    assert request.method == "personal_sign"
    assert request.params == ["0x68656c6c6f", @account]
    assert request.account == @account
    assert request.summary == %{kind: :personal_sign, message: "0x68656c6c6f"}
    assert byte_size(request.fingerprint) == 32

    assert {:error, :account_not_connected} =
             WalletRequest.validate("personal_sign", ["hello", @recipient], [@account])
  end

  test "validates bounded typed data and extracts review fields" do
    typed_data =
      Jason.encode!(%{
        "domain" => %{"name" => "Example", "chainId" => 8453},
        "primaryType" => "Mail",
        "types" => %{"Mail" => []},
        "message" => %{"contents" => "Hello"}
      })

    assert {:ok, request} =
             WalletRequest.validate("eth_signTypedData_v4", [@account, typed_data], [@account])

    assert request.summary == %{
             kind: :typed_data,
             domain: "Example",
             primary_type: "Mail",
             chain_id: "8453"
           }

    assert {:error, :invalid_params} =
             WalletRequest.validate("eth_signTypedData_v4", [@account, "not-json"], [@account])
  end

  test "allows one bounded transaction and rejects hidden or malformed fields" do
    transaction = %{
      "from" => @account,
      "to" => @recipient,
      "value" => "0x1",
      "data" => "0x1234",
      "gas" => "0x5208",
      "maxFeePerGas" => "0x10"
    }

    assert {:ok, request} =
             WalletRequest.validate("eth_sendTransaction", [transaction], [@account])

    assert request.params == [transaction]

    assert request.summary == %{
             kind: :transaction,
             from: @account,
             to: @recipient,
             value: "0x1",
             data: "0x1234",
             gas: "0x5208"
           }

    assert {:error, :invalid_params} =
             WalletRequest.validate(
               "eth_sendTransaction",
               [Map.put(transaction, "privateKey", "secret")],
               [@account]
             )

    assert {:error, :invalid_params} =
             WalletRequest.validate("eth_sendTransaction", [transaction, transaction], [@account])
  end

  test "rejects unsupported methods and malformed envelopes" do
    assert {:error, :unsupported_method} = WalletRequest.validate("eth_sign", [], [@account])
    assert {:error, :invalid_params} = WalletRequest.validate("personal_sign", [], [@account])
    assert {:error, :invalid_params} = WalletRequest.validate("personal_sign", nil, [@account])
  end

  test "fails closed on oversized, deeply nested, or dangerous signing data" do
    oversized = String.duplicate("a", 131_073)

    assert {:error, :invalid_params} =
             WalletRequest.validate("personal_sign", [oversized, @account], [@account])

    dangerous = Jason.encode!(%{"domain" => %{}, "message" => %{"constructor" => "x"}})

    assert {:error, :invalid_params} =
             WalletRequest.validate("eth_signTypedData_v4", [@account, dangerous], [@account])

    nested = Enum.reduce(1..18, %{"value" => true}, fn _, value -> %{"next" => value} end)

    assert {:error, :invalid_params} =
             WalletRequest.validate(
               "eth_signTypedData_v4",
               [@account, Jason.encode!(nested)],
               [@account]
             )
  end

  test "accepts data-only transactions and rejects malformed transaction values" do
    uppercase_account = String.upcase(@account, :ascii) |> String.replace_prefix("0X", "0x")

    assert {:ok, request} =
             WalletRequest.validate(
               "eth_sendTransaction",
               [%{"from" => uppercase_account, "data" => "0x12", "chainId" => "0x2105"}],
               [@account]
             )

    assert request.account == uppercase_account

    for transaction <- [
          %{"from" => @account},
          %{"from" => @account, "to" => "invalid"},
          %{"from" => @account, "data" => "0x1"},
          %{"from" => @account, "to" => @recipient, "value" => "0x00"},
          %{"from" => 12, "to" => @recipient}
        ] do
      assert {:error, :invalid_params} =
               WalletRequest.validate("eth_sendTransaction", [transaction], [@account])
    end

    assert {:error, :account_not_connected} =
             WalletRequest.validate(
               "eth_sendTransaction",
               [%{"from" => @recipient, "to" => @account}],
               [@account]
             )
  end

  test "typed-data review tolerates absent display metadata without inventing it" do
    encoded = Jason.encode!(%{"domain" => %{"chainId" => "0x2105"}, "message" => %{}})

    assert {:ok, request} =
             WalletRequest.validate("eth_signTypedData_v4", [@account, encoded], [@account])

    assert request.summary.domain == nil
    assert request.summary.primary_type == nil
    assert request.summary.chain_id == "0x2105"

    without_chain = Jason.encode!(%{"domain" => %{}, "message" => %{}})

    assert {:ok, chainless} =
             WalletRequest.validate("eth_signTypedData_v4", [@account, without_chain], [@account])

    assert chainless.summary.chain_id == nil

    assert {:error, :account_not_connected} =
             WalletRequest.validate(
               "eth_signTypedData_v4",
               [@recipient, without_chain],
               [@account]
             )

    assert {:error, :invalid_params} =
             WalletRequest.validate("eth_signTypedData_v4", [], [@account])

    assert {:error, :invalid_params} =
             WalletRequest.validate("personal_sign", ["hello", "not-an-address"], [@account])

    assert {:error, :invalid_params} =
             WalletRequest.validate("personal_sign", ["hello", 12], [@account])

    wide_array = Jason.encode!(%{"domain" => %{}, "message" => Enum.to_list(1..257)})

    assert {:error, :invalid_params} =
             WalletRequest.validate("eth_signTypedData_v4", [@account, wide_array], [@account])
  end
end
