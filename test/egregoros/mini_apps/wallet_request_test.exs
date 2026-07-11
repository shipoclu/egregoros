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

  test "normalizes personal-sign bytes and rejects non-data or overlong messages" do
    uppercase_account = String.upcase(@account, :ascii) |> String.replace_prefix("0X", "0x")

    assert {:ok, request} =
             WalletRequest.validate("personal_sign", ["0xAABB", uppercase_account], [@account])

    assert request.params == ["0xaabb", @account]
    assert request.summary.message == "0xaabb"

    for message <- ["hello", "0x1", "0xgg", "0x" <> String.duplicate("aa", 65_537)] do
      assert {:error, :invalid_params} =
               WalletRequest.validate("personal_sign", [message, @account], [@account])
    end
  end

  test "binds an execution token to the exact reviewed launch, request, payload, and context" do
    assert {:ok, request} =
             WalletRequest.validate("personal_sign", ["0x12", @account], [@account])

    assert {:ok, reviewed} =
             WalletRequest.bind_review(request, "launch-1", "request-1", "0x2105", [@account])

    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    assert {:ok, execution} = WalletRequest.issue_execution(reviewed, token)

    assert WalletRequest.execution_matches?(execution, "launch-1", "request-1", token)
    refute WalletRequest.execution_matches?(execution, "launch-2", "request-1", token)
    refute WalletRequest.execution_matches?(execution, "launch-1", "request-2", token)

    refute WalletRequest.execution_matches?(
             execution,
             "launch-1",
             "request-1",
             String.duplicate("x", 43)
           )

    refute WalletRequest.execution_matches?(
             %{execution | params: ["0x13", @account]},
             "launch-1",
             "request-1",
             token
           )
  end

  test "rejects transaction and typed-data chains that differ from the reviewed wallet chain" do
    assert {:ok, transaction} =
             WalletRequest.validate(
               "eth_sendTransaction",
               [%{"from" => @account, "to" => @recipient, "chainId" => "0x1"}],
               [@account]
             )

    assert {:error, :chain_mismatch} =
             WalletRequest.bind_review(
               transaction,
               "launch-1",
               "request-1",
               "0x2105",
               [@account]
             )

    typed_data =
      Jason.encode!(%{
        "domain" => %{"chainId" => "8453"},
        "primaryType" => "Empty",
        "types" => %{
          "EIP712Domain" => [%{"name" => "chainId", "type" => "uint256"}],
          "Empty" => []
        },
        "message" => %{}
      })

    assert {:ok, typed} =
             WalletRequest.validate("eth_signTypedData_v4", [@account, typed_data], [@account])

    assert {:error, :chain_mismatch} =
             WalletRequest.bind_review(
               typed,
               "launch-1",
               "request-2",
               "0x1",
               [@account]
             )
  end

  test "validates bounded typed data and extracts review fields" do
    typed_data =
      Jason.encode!(%{
        "domain" => %{"name" => "Example", "chainId" => 8453},
        "primaryType" => "Mail",
        "types" => %{
          "EIP712Domain" => [
            %{"name" => "name", "type" => "string"},
            %{"name" => "chainId", "type" => "uint256"}
          ],
          "Mail" => [%{"name" => "contents", "type" => "string"}]
        },
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

  test "rejects duplicate or non-schema typed data and normalizes the exact review payload" do
    uppercase_account = String.upcase(@account, :ascii) |> String.replace_prefix("0X", "0x")
    uppercase_recipient = String.upcase(@recipient, :ascii) |> String.replace_prefix("0X", "0x")

    valid = %{
      "domain" => %{"name" => "Example", "chainId" => "0x2105"},
      "primaryType" => "Mail",
      "types" => %{
        "EIP712Domain" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "chainId", "type" => "uint256"}
        ],
        "Mail" => [
          %{"name" => "contents", "type" => "string"},
          %{"name" => "recipients", "type" => "address[]"}
        ]
      },
      "message" => %{"contents" => "Hello", "recipients" => [uppercase_recipient]}
    }

    assert {:ok, request} =
             WalletRequest.validate(
               "eth_signTypedData_v4",
               [uppercase_account, Jason.encode!(valid)],
               [@account]
             )

    [normalized_account, normalized_json] = request.params
    assert normalized_account == @account
    assert get_in(Jason.decode!(normalized_json), ["message", "recipients"]) == [@recipient]

    assert Jason.decode!(request.review_json) == %{
             "method" => "eth_signTypedData_v4",
             "params" => request.params
           }

    duplicate =
      ~s({"types":{"EIP712Domain":[],"Mail":[]},"primaryType":"Mail","domain":{},"message":{},"message":{"hidden":true}})

    extra = Map.put(valid, "unexpected", true)
    missing_type = put_in(valid, ["primaryType"], "Unknown")
    extra_domain = put_in(valid, ["domain", "callback"], "https://evil.example")
    undeclared_message = put_in(valid, ["message", "hidden"], "value")

    for encoded <-
          Enum.map([extra, missing_type, extra_domain, undeclared_message], &Jason.encode!/1) ++
            [duplicate] do
      assert {:error, :invalid_params} =
               WalletRequest.validate("eth_signTypedData_v4", [@account, encoded], [@account])
    end
  end

  test "bounds typed-data types, values, arrays, and numeric widths" do
    fixture = fn type, value ->
      Jason.encode!(%{
        "domain" => %{},
        "primaryType" => "Message",
        "types" => %{
          "EIP712Domain" => [],
          "Message" => [%{"name" => "value", "type" => type}]
        },
        "message" => %{"value" => value}
      })
    end

    for encoded <- [
          fixture.("string", String.duplicate("a", 8_193)),
          fixture.("uint8", "256"),
          String.replace(fixture.("uint8", "0"), ~s("value":"0"), ~s("value":-0)),
          fixture.("bytes32", "0x12"),
          fixture.("address[]", List.duplicate(@account, 129)),
          fixture.("NotDeclared", %{})
        ] do
      assert {:error, :invalid_params} =
               WalletRequest.validate("eth_signTypedData_v4", [@account, encoded], [@account])
    end
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
             gas: "0x5208",
             chain_id: nil
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

  test "normalizes and bounds quantities and EIP-2930 access lists" do
    storage_key = "0x" <> String.duplicate("AB", 32)
    uppercase_account = String.upcase(@account, :ascii) |> String.replace_prefix("0X", "0x")
    uppercase_recipient = String.upcase(@recipient, :ascii) |> String.replace_prefix("0X", "0x")

    transaction = %{
      "from" => uppercase_account,
      "to" => uppercase_recipient,
      "value" => "0xAB",
      "data" => "0xAABB",
      "type" => "0x2",
      "accessList" => [
        %{"address" => uppercase_recipient, "storageKeys" => [storage_key]}
      ]
    }

    assert {:ok, request} =
             WalletRequest.validate("eth_sendTransaction", [transaction], [@account])

    [normalized] = request.params
    assert normalized["from"] == @account
    assert normalized["to"] == @recipient
    assert normalized["value"] == "0xab"
    assert normalized["data"] == "0xaabb"

    assert normalized["accessList"] == [
             %{"address" => @recipient, "storageKeys" => [String.downcase(storage_key)]}
           ]

    invalid = [
      Map.put(transaction, "value", "0x1" <> String.duplicate("0", 64)),
      Map.put(
        transaction,
        "accessList",
        List.duplicate(%{"address" => @recipient, "storageKeys" => []}, 129)
      ),
      put_in(transaction, ["accessList"], [%{"address" => @recipient, "storageKeys" => ["0x12"]}]),
      Map.put(transaction, "gasPrice", "0x1") |> Map.put("maxFeePerGas", "0x2")
    ]

    for params <- invalid do
      assert {:error, :invalid_params} =
               WalletRequest.validate("eth_sendTransaction", [params], [@account])
    end
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
    encoded =
      Jason.encode!(%{
        "domain" => %{"chainId" => "0x2105"},
        "primaryType" => "Empty",
        "types" => %{
          "EIP712Domain" => [%{"name" => "chainId", "type" => "uint256"}],
          "Empty" => []
        },
        "message" => %{}
      })

    assert {:ok, request} =
             WalletRequest.validate("eth_signTypedData_v4", [@account, encoded], [@account])

    assert request.summary.domain == nil
    assert request.summary.primary_type == "Empty"
    assert request.summary.chain_id == "8453"

    without_chain =
      Jason.encode!(%{
        "domain" => %{},
        "primaryType" => "Empty",
        "types" => %{"EIP712Domain" => [], "Empty" => []},
        "message" => %{}
      })

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

    wide_array =
      Jason.encode!(%{
        "domain" => %{},
        "primaryType" => "Wide",
        "types" => %{
          "EIP712Domain" => [],
          "Wide" => [%{"name" => "values", "type" => "uint256[]"}]
        },
        "message" => %{"values" => Enum.to_list(1..257)}
      })

    assert {:error, :invalid_params} =
             WalletRequest.validate("eth_signTypedData_v4", [@account, wide_array], [@account])
  end
end
