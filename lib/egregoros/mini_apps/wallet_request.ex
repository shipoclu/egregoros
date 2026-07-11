defmodule Egregoros.MiniApps.WalletRequest do
  @moduledoc false

  @max_payload_bytes 131_072
  @max_data_bytes 262_146
  @address ~r/^0x[0-9a-fA-F]{40}$/
  @data ~r/^0x(?:[0-9a-fA-F]{2})*$/
  @quantity ~r/^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/
  @transaction_fields ~w(from to data value gas gasPrice maxFeePerGas maxPriorityFeePerGas nonce chainId)
  @quantity_fields ~w(value gas gasPrice maxFeePerGas maxPriorityFeePerGas nonce chainId)
  @dangerous_keys ~w(__proto__ constructor prototype)

  def validate("personal_sign" = method, [message, account] = params, approved_accounts)
      when is_binary(message) and byte_size(message) <= @max_payload_bytes do
    with :ok <- validate_account(account, approved_accounts) do
      request(method, params, account, %{kind: :personal_sign, message: message})
    end
  end

  def validate("personal_sign", _params, _approved_accounts), do: {:error, :invalid_params}

  def validate("eth_signTypedData_v4" = method, [account, encoded] = params, approved_accounts)
      when is_binary(encoded) and byte_size(encoded) <= @max_payload_bytes do
    with :ok <- validate_account(account, approved_accounts),
         {:ok, typed_data} when is_map(typed_data) <- Jason.decode(encoded),
         true <- safe_json?(typed_data) do
      summary = %{
        kind: :typed_data,
        domain: typed_data |> get_in(["domain", "name"]) |> bounded_label(),
        primary_type: typed_data |> Map.get("primaryType") |> bounded_label(),
        chain_id: typed_data |> get_in(["domain", "chainId"]) |> bounded_chain_id()
      }

      request(method, params, account, summary)
    else
      {:error, :account_not_connected} = error -> error
      _other -> {:error, :invalid_params}
    end
  end

  def validate("eth_signTypedData_v4", _params, _approved_accounts),
    do: {:error, :invalid_params}

  def validate("eth_sendTransaction" = method, [transaction] = params, approved_accounts)
      when is_map(transaction) do
    account = Map.get(transaction, "from")

    with true <- valid_transaction?(transaction),
         :ok <- validate_account(account, approved_accounts) do
      summary = %{
        kind: :transaction,
        from: account,
        to: Map.get(transaction, "to"),
        value: Map.get(transaction, "value"),
        data: Map.get(transaction, "data"),
        gas: Map.get(transaction, "gas")
      }

      request(method, params, account, summary)
    else
      {:error, :account_not_connected} = error -> error
      _other -> {:error, :invalid_params}
    end
  end

  def validate("eth_sendTransaction", _params, _approved_accounts),
    do: {:error, :invalid_params}

  def validate(method, _params, _approved_accounts)
      when method not in ["personal_sign", "eth_signTypedData_v4", "eth_sendTransaction"],
      do: {:error, :unsupported_method}

  defp request(method, params, account, summary) do
    {:ok,
     %{
       method: method,
       params: params,
       account: account,
       summary: summary,
       fingerprint: :crypto.hash(:sha256, :erlang.term_to_binary({method, params}))
     }}
  end

  defp validate_account(account, approved_accounts) when is_binary(account) do
    approved = MapSet.new(approved_accounts, &String.downcase/1)

    cond do
      not Regex.match?(@address, account) -> {:error, :invalid_params}
      MapSet.member?(approved, String.downcase(account)) -> :ok
      true -> {:error, :account_not_connected}
    end
  end

  defp validate_account(_account, _approved_accounts), do: {:error, :invalid_params}

  defp valid_transaction?(transaction) do
    keys = Map.keys(transaction)
    data = Map.get(transaction, "data")

    Enum.all?(keys, &(&1 in @transaction_fields)) and
      valid_address?(Map.get(transaction, "from")) and
      valid_optional_address?(Map.get(transaction, "to")) and
      valid_optional_data?(data) and
      Enum.all?(@quantity_fields, &valid_optional_quantity?(Map.get(transaction, &1))) and
      (Map.has_key?(transaction, "to") or Map.has_key?(transaction, "data"))
  end

  defp valid_optional_address?(nil), do: true
  defp valid_optional_address?(value), do: valid_address?(value)

  defp valid_address?(value), do: is_binary(value) and Regex.match?(@address, value)

  defp valid_optional_data?(nil), do: true

  defp valid_optional_data?(value),
    do: is_binary(value) and byte_size(value) <= @max_data_bytes and Regex.match?(@data, value)

  defp valid_optional_quantity?(nil), do: true

  defp valid_optional_quantity?(value),
    do: is_binary(value) and Regex.match?(@quantity, value)

  defp safe_json?(_value, depth) when depth > 16, do: false

  defp safe_json?(value, _depth) when is_nil(value) or is_binary(value) or is_boolean(value),
    do: true

  defp safe_json?(value, _depth) when is_number(value), do: true

  defp safe_json?(value, depth) when is_list(value) and length(value) <= 256,
    do: Enum.all?(value, &safe_json?(&1, depth + 1))

  defp safe_json?(value, depth) when is_map(value) and map_size(value) <= 256 do
    Enum.all?(value, fn {key, item} ->
      is_binary(key) and key not in @dangerous_keys and safe_json?(item, depth + 1)
    end)
  end

  defp safe_json?(_value, _depth), do: false
  defp safe_json?(value), do: safe_json?(value, 0)

  defp bounded_label(value) when is_binary(value), do: String.slice(value, 0, 256)
  defp bounded_label(_value), do: nil

  defp bounded_chain_id(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp bounded_chain_id(value) when is_binary(value), do: String.slice(value, 0, 64)
  defp bounded_chain_id(_value), do: nil
end
