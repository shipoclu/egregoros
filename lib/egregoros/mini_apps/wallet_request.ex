defmodule Egregoros.MiniApps.WalletRequest do
  @moduledoc false

  import Bitwise

  @max_typed_data_bytes 65_536
  @max_binary_bytes 65_536
  @max_string_bytes 8_192
  @max_depth 12
  @max_nodes 4_096
  @max_collection 128
  @max_types 32
  @max_fields 32
  @max_access_list 128
  @max_storage_keys 256
  @max_accounts 16
  @address ~r/^0x[0-9a-fA-F]{40}$/
  @data ~r/^0x(?:[0-9a-fA-F]{2})*$/
  @storage_key ~r/^0x[0-9a-fA-F]{64}$/
  @quantity ~r/^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/
  @decimal ~r/^(?:0|[1-9][0-9]*)$/
  @signed_decimal ~r/^(?:0|-?[1-9][0-9]*)$/
  @identifier ~r/^[A-Za-z_][A-Za-z0-9_]{0,63}$/
  @transaction_fields ~w(from to data value gas gasPrice maxFeePerGas maxPriorityFeePerGas nonce chainId type accessList)
  @quantity_bits %{
    "value" => 256,
    "gas" => 64,
    "gasPrice" => 256,
    "maxFeePerGas" => 256,
    "maxPriorityFeePerGas" => 256,
    "nonce" => 64,
    "chainId" => 256,
    "type" => 8
  }
  @typed_data_keys ~w(types primaryType domain message)
  @domain_types %{
    "name" => "string",
    "version" => "string",
    "chainId" => "uint256",
    "verifyingContract" => "address",
    "salt" => "bytes32"
  }
  @dangerous_keys ~w(__proto__ constructor prototype)
  @uint256_max (1 <<< 256) - 1

  def validate("personal_sign" = method, [message, account], approved_accounts) do
    with {:ok, account} <- normalize_approved_account(account, approved_accounts),
         {:ok, message} <- normalize_data(message, @max_binary_bytes) do
      request(method, [message, account], account, %{kind: :personal_sign, message: message})
    end
  end

  def validate("personal_sign", _params, _approved_accounts), do: {:error, :invalid_params}

  def validate("eth_signTypedData_v4" = method, [account, encoded], approved_accounts) do
    with {:ok, account} <- normalize_approved_account(account, approved_accounts),
         {:ok, typed_data} <- decode_typed_data(encoded),
         {:ok, typed_data} <- normalize_typed_data(typed_data),
         {:ok, encoded} <- Jason.encode(typed_data),
         true <- byte_size(encoded) <= @max_typed_data_bytes or {:error, :invalid_params} do
      summary = %{
        kind: :typed_data,
        domain: get_in(typed_data, ["domain", "name"]),
        primary_type: typed_data["primaryType"],
        chain_id: typed_data |> get_in(["domain", "chainId"]) |> display_chain_id()
      }

      request(method, [account, encoded], account, summary)
    else
      {:error, :account_not_connected} = error -> error
      _other -> {:error, :invalid_params}
    end
  end

  def validate("eth_signTypedData_v4", _params, _approved_accounts),
    do: {:error, :invalid_params}

  def validate("eth_sendTransaction" = method, [transaction], approved_accounts)
      when is_map(transaction) do
    with {:ok, account} <- normalize_approved_account(transaction["from"], approved_accounts),
         {:ok, transaction} <- normalize_transaction(transaction, account) do
      summary = %{
        kind: :transaction,
        from: account,
        to: transaction["to"],
        value: transaction["value"],
        data: transaction["data"],
        gas: transaction["gas"],
        chain_id: transaction["chainId"]
      }

      request(method, [transaction], account, summary)
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

  def normalize_chain_id(value), do: normalize_quantity(value, 256)

  def normalize_accounts(accounts, options \\ [])

  def normalize_accounts(accounts, options)
      when is_list(accounts) and length(accounts) <= @max_accounts do
    allow_empty? = Keyword.get(options, :allow_empty, false)

    with true <- allow_empty? or accounts != [] or {:error, :invalid_accounts},
         normalized when length(normalized) == length(accounts) <-
           Enum.map(accounts, &normalize_address/1),
         true <-
           Enum.all?(normalized, &match?({:ok, _account}, &1)) or {:error, :invalid_accounts},
         normalized <- Enum.map(normalized, fn {:ok, account} -> account end),
         true <- Enum.uniq(normalized) == normalized or {:error, :invalid_accounts} do
      {:ok, normalized}
    else
      _other -> {:error, :invalid_accounts}
    end
  end

  def normalize_accounts(_accounts, _options), do: {:error, :invalid_accounts}

  def validate_result("eth_chainId", result), do: normalize_chain_id(result)

  def validate_result("eth_requestAccounts", result), do: normalize_accounts(result)

  def validate_result("eth_accounts", result),
    do: normalize_accounts(result, allow_empty: true)

  def validate_result(method, result)
      when method in ["personal_sign", "eth_signTypedData_v4"] do
    normalize_fixed_data(result, 65)
  end

  def validate_result("eth_sendTransaction", result), do: normalize_fixed_data(result, 32)
  def validate_result(_method, _result), do: {:error, :invalid_result}

  def bind_review(request, launch_id, request_id, chain_id, accounts)
      when is_map(request) and is_binary(launch_id) and is_binary(request_id) do
    with {:ok, chain_id} <- normalize_chain_id(chain_id),
         {:ok, accounts} <- normalize_accounts(accounts),
         :ok <- payload_chain_matches(request, chain_id),
         true <- request.account in accounts or {:error, :account_not_connected} do
      bind_execution(request, launch_id, request_id, chain_id, accounts)
    end
  end

  def bind_review(_request, _launch_id, _request_id, _chain_id, _accounts),
    do: {:error, :invalid_context}

  def bind_execution(request, launch_id, request_id, chain_id \\ nil, accounts \\ nil)

  def bind_execution(request, launch_id, request_id, chain_id, accounts)
      when is_map(request) and is_binary(launch_id) and is_binary(request_id) do
    with method when is_binary(method) <- request[:method],
         params when is_list(params) <- request[:params] do
      binding = binding_fingerprint(launch_id, request_id, method, params, chain_id, accounts)

      {:ok,
       Map.merge(request, %{
         launch_id: launch_id,
         request_id: request_id,
         expected_chain_id: chain_id,
         expected_accounts: accounts,
         binding: binding
       })}
    else
      _other -> {:error, :invalid_context}
    end
  end

  def bind_execution(_request, _launch_id, _request_id, _chain_id, _accounts),
    do: {:error, :invalid_context}

  def issue_execution(request, token)
      when is_map(request) and is_binary(token) and byte_size(token) == 43 do
    execution_binding = :crypto.hash(:sha256, request.binding <> token)
    {:ok, Map.merge(request, %{execution_token: token, execution_binding: execution_binding})}
  end

  def issue_execution(_request, _token), do: {:error, :invalid_execution}

  def execution_matches?(request, launch_id, request_id, token)
      when is_map(request) and is_binary(launch_id) and is_binary(request_id) and is_binary(token) do
    with expected when is_binary(expected) <- request[:execution_token],
         binding when is_binary(binding) <- request[:binding],
         execution_binding when is_binary(execution_binding) <- request[:execution_binding],
         true <- request[:launch_id] == launch_id,
         true <- request[:request_id] == request_id,
         true <- byte_size(expected) == byte_size(token),
         true <- Plug.Crypto.secure_compare(expected, token),
         true <-
           Plug.Crypto.secure_compare(execution_binding, :crypto.hash(:sha256, binding <> token)),
         true <-
           Plug.Crypto.secure_compare(
             binding,
             binding_fingerprint(
               launch_id,
               request_id,
               request.method,
               request.params,
               request[:expected_chain_id],
               request[:expected_accounts]
             )
           ) do
      true
    else
      _other -> false
    end
  end

  def execution_matches?(_request, _launch_id, _request_id, _token), do: false

  def normalize_error_code(code)
      when code in [4001, 4100, 4200, 4900, 4901] or code in -32_768..-32_000,
      do: code

  def normalize_error_code(_code), do: 4001

  defp request(method, params, account, summary) do
    review_json = Jason.encode!(%{"method" => method, "params" => params})

    {:ok,
     %{
       method: method,
       params: params,
       account: account,
       summary: summary,
       review_json: review_json,
       fingerprint: :crypto.hash(:sha256, :erlang.term_to_binary({method, params}))
     }}
  end

  defp binding_fingerprint(launch_id, request_id, method, params, chain_id, accounts) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({launch_id, request_id, method, params, chain_id, accounts})
    )
  end

  defp payload_chain_matches(%{summary: %{chain_id: nil}}, _chain_id), do: :ok

  defp payload_chain_matches(%{summary: %{chain_id: payload_chain_id}}, chain_id) do
    if chain_integer(payload_chain_id) == chain_integer(chain_id),
      do: :ok,
      else: {:error, :chain_mismatch}
  end

  defp payload_chain_matches(_request, _chain_id), do: :ok

  defp chain_integer("0x" <> encoded), do: String.to_integer(encoded, 16)
  defp chain_integer(encoded), do: String.to_integer(encoded, 10)

  defp normalize_approved_account(account, approved_accounts) do
    with {:ok, account} <- normalize_address(account) do
      approved =
        approved_accounts
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.downcase/1)
        |> MapSet.new()

      if MapSet.member?(approved, account),
        do: {:ok, account},
        else: {:error, :account_not_connected}
    end
  end

  defp normalize_address(value) when is_binary(value) do
    if Regex.match?(@address, value),
      do: {:ok, String.downcase(value)},
      else: {:error, :invalid_params}
  end

  defp normalize_address(_value), do: {:error, :invalid_params}

  defp normalize_data(value, max_bytes) when is_binary(value) do
    if byte_size(value) <= 2 + max_bytes * 2 and Regex.match?(@data, value),
      do: {:ok, String.downcase(value)},
      else: {:error, :invalid_params}
  end

  defp normalize_data(_value, _max_bytes), do: {:error, :invalid_params}

  defp normalize_fixed_data(value, bytes) when is_binary(value) do
    if byte_size(value) == 2 + bytes * 2 and Regex.match?(@data, value),
      do: {:ok, String.downcase(value)},
      else: {:error, :invalid_result}
  end

  defp normalize_fixed_data(_value, _bytes), do: {:error, :invalid_result}

  defp normalize_quantity(value, bits) when is_binary(value) do
    max_nibbles = div(bits + 3, 4)

    if Regex.match?(@quantity, value) and byte_size(value) - 2 <= max_nibbles,
      do: {:ok, String.downcase(value)},
      else: {:error, :invalid_params}
  end

  defp normalize_quantity(_value, _bits), do: {:error, :invalid_params}

  defp normalize_transaction(transaction, account) do
    keys = Map.keys(transaction)

    with true <- Enum.all?(keys, &(is_binary(&1) and &1 in @transaction_fields)),
         true <- transaction["from"] != nil,
         {:ok, normalized} <- normalize_transaction_fields(transaction, account),
         true <- normalized["to"] != nil or normalized["data"] not in [nil, "0x"],
         true <- compatible_fee_fields?(normalized),
         true <- priority_fee_allowed?(normalized) do
      {:ok, normalized}
    else
      _other -> {:error, :invalid_params}
    end
  end

  defp normalize_transaction_fields(transaction, account) do
    Enum.reduce_while(transaction, {:ok, %{}}, fn
      {"from", _value}, {:ok, normalized} ->
        {:cont, {:ok, Map.put(normalized, "from", account)}}

      {key, value}, {:ok, normalized} when key in ["to"] ->
        continue_normalized(normalized, key, normalize_address(value))

      {"data" = key, value}, {:ok, normalized} ->
        continue_normalized(normalized, key, normalize_data(value, @max_binary_bytes))

      {"accessList" = key, value}, {:ok, normalized} ->
        continue_normalized(normalized, key, normalize_access_list(value))

      {key, value}, {:ok, normalized} ->
        continue_normalized(normalized, key, normalize_quantity(value, @quantity_bits[key]))
    end)
  end

  defp continue_normalized(normalized, key, {:ok, value}),
    do: {:cont, {:ok, Map.put(normalized, key, value)}}

  defp continue_normalized(_normalized, _key, _error), do: {:halt, {:error, :invalid_params}}

  defp normalize_access_list(entries)
       when is_list(entries) and length(entries) <= @max_access_list do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, normalized} ->
      case normalize_access_list_entry(entry) do
        {:ok, entry} -> {:cont, {:ok, [entry | normalized]}}
        _error -> {:halt, {:error, :invalid_params}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_access_list(_entries), do: {:error, :invalid_params}

  defp normalize_access_list_entry(%{"address" => address, "storageKeys" => keys} = entry)
       when map_size(entry) == 2 and is_list(keys) and length(keys) <= @max_storage_keys do
    with {:ok, address} <- normalize_address(address),
         true <- Enum.all?(keys, &(is_binary(&1) and Regex.match?(@storage_key, &1))) do
      {:ok, %{"address" => address, "storageKeys" => Enum.map(keys, &String.downcase/1)}}
    else
      _other -> {:error, :invalid_params}
    end
  end

  defp normalize_access_list_entry(_entry), do: {:error, :invalid_params}

  defp compatible_fee_fields?(transaction) do
    not (Map.has_key?(transaction, "gasPrice") and
           (Map.has_key?(transaction, "maxFeePerGas") or
              Map.has_key?(transaction, "maxPriorityFeePerGas")))
  end

  defp priority_fee_allowed?(%{
         "maxFeePerGas" => maximum,
         "maxPriorityFeePerGas" => priority
       }) do
    quantity_integer(priority) <= quantity_integer(maximum)
  end

  defp priority_fee_allowed?(_transaction), do: true

  defp quantity_integer("0x" <> encoded), do: String.to_integer(encoded, 16)

  defp decode_typed_data(encoded)
       when is_binary(encoded) and byte_size(encoded) <= @max_typed_data_bytes do
    with true <- canonical_json_numbers?(encoded),
         {:ok, decoded} <- Jason.decode(encoded, objects: :ordered_objects),
         {:ok, normalized, _remaining} <- normalize_json(decoded, 0, @max_nodes) do
      {:ok, normalized}
    else
      _other -> {:error, :invalid_params}
    end
  end

  defp decode_typed_data(_encoded), do: {:error, :invalid_params}

  defp canonical_json_numbers?(encoded), do: scan_json_numbers(encoded, false)

  defp scan_json_numbers(<<>>, _in_string?), do: true

  defp scan_json_numbers(<<?\\, _escaped, rest::binary>>, true),
    do: scan_json_numbers(rest, true)

  defp scan_json_numbers(<<?\", rest::binary>>, true),
    do: scan_json_numbers(rest, false)

  defp scan_json_numbers(<<_byte, rest::binary>>, true),
    do: scan_json_numbers(rest, true)

  defp scan_json_numbers(<<?\", rest::binary>>, false),
    do: scan_json_numbers(rest, true)

  defp scan_json_numbers(<<?-, ?0, rest::binary>>, false) do
    not json_number_terminated?(rest) and scan_json_numbers(rest, false)
  end

  defp scan_json_numbers(<<_byte, rest::binary>>, false),
    do: scan_json_numbers(rest, false)

  defp json_number_terminated?(<<byte, rest::binary>>) when byte in [9, 10, 13, 32],
    do: json_number_terminated?(rest)

  defp json_number_terminated?(<<>>), do: true
  defp json_number_terminated?(<<byte, _rest::binary>>), do: byte in [?,, ?], ?}]

  defp normalize_json(_value, depth, _remaining) when depth > @max_depth,
    do: {:error, :invalid_params}

  defp normalize_json(_value, _depth, remaining) when remaining <= 0,
    do: {:error, :invalid_params}

  defp normalize_json(%Jason.OrderedObject{values: values}, depth, remaining)
       when length(values) <= @max_collection do
    keys = Enum.map(values, &elem(&1, 0))

    with true <- Enum.uniq(keys) == keys,
         true <- Enum.all?(keys, &valid_json_key?/1) do
      Enum.reduce_while(values, {:ok, %{}, remaining - 1}, fn {key, value},
                                                              {:ok, normalized, left} ->
        case normalize_json(value, depth + 1, left) do
          {:ok, value, left} -> {:cont, {:ok, Map.put(normalized, key, value), left}}
          _error -> {:halt, {:error, :invalid_params}}
        end
      end)
    else
      _other -> {:error, :invalid_params}
    end
  end

  defp normalize_json(%Jason.OrderedObject{}, _depth, _remaining),
    do: {:error, :invalid_params}

  defp normalize_json(value, depth, remaining)
       when is_list(value) and length(value) <= @max_collection do
    Enum.reduce_while(value, {:ok, [], remaining - 1}, fn item, {:ok, normalized, left} ->
      case normalize_json(item, depth + 1, left) do
        {:ok, item, left} -> {:cont, {:ok, [item | normalized], left}}
        _error -> {:halt, {:error, :invalid_params}}
      end
    end)
    |> case do
      {:ok, normalized, left} -> {:ok, Enum.reverse(normalized), left}
      error -> error
    end
  end

  defp normalize_json(value, _depth, remaining)
       when is_binary(value) and byte_size(value) <= @max_string_bytes,
       do: {:ok, value, remaining - 1}

  defp normalize_json(value, _depth, remaining)
       when is_integer(value) and value >= -@uint256_max and value <= @uint256_max,
       do: {:ok, value, remaining - 1}

  defp normalize_json(value, _depth, remaining) when is_boolean(value) or is_nil(value),
    do: {:ok, value, remaining - 1}

  defp normalize_json(_value, _depth, _remaining), do: {:error, :invalid_params}

  defp valid_json_key?(key) do
    is_binary(key) and byte_size(key) in 1..64 and key not in @dangerous_keys
  end

  defp normalize_typed_data(typed_data) when is_map(typed_data) do
    with true <- exact_keys?(typed_data, @typed_data_keys),
         {:ok, types} <- normalize_types(typed_data["types"]),
         primary_type when is_binary(primary_type) <- typed_data["primaryType"],
         true <- valid_identifier?(primary_type),
         true <- Map.has_key?(types, "EIP712Domain") and Map.has_key?(types, primary_type),
         :ok <- validate_type_references(types),
         {:ok, domain} <- normalize_domain(typed_data["domain"], types),
         {:ok, message} <-
           normalize_struct(typed_data["message"], types[primary_type], types, 0) do
      {:ok,
       %{
         "types" => types,
         "primaryType" => primary_type,
         "domain" => domain,
         "message" => message
       }}
    else
      _other -> {:error, :invalid_params}
    end
  end

  defp normalize_typed_data(_typed_data), do: {:error, :invalid_params}

  defp normalize_types(types) when is_map(types) and map_size(types) in 1..@max_types do
    Enum.reduce_while(types, {:ok, %{}}, fn {name, fields}, {:ok, normalized} ->
      case normalize_type_fields(name, fields) do
        {:ok, fields} -> {:cont, {:ok, Map.put(normalized, name, fields)}}
        _error -> {:halt, {:error, :invalid_params}}
      end
    end)
  end

  defp normalize_types(_types), do: {:error, :invalid_params}

  defp normalize_type_fields(name, fields)
       when is_binary(name) and is_list(fields) and length(fields) <= @max_fields do
    with true <- valid_identifier?(name),
         true <- Enum.all?(fields, &valid_type_field?/1),
         names <- Enum.map(fields, & &1["name"]),
         true <- Enum.uniq(names) == names do
      {:ok, fields}
    else
      _other -> {:error, :invalid_params}
    end
  end

  defp normalize_type_fields(_name, _fields), do: {:error, :invalid_params}

  defp valid_type_field?(%{"name" => name, "type" => type} = field) do
    map_size(field) == 2 and valid_identifier?(name) and is_binary(type) and
      byte_size(type) <= 96
  end

  defp valid_type_field?(_field), do: false

  defp validate_type_references(types) do
    if Enum.all?(types, fn {_name, fields} ->
         Enum.all?(fields, fn %{"type" => type} ->
           match?({:ok, _, _}, parse_type(type, types))
         end)
       end),
       do: :ok,
       else: {:error, :invalid_params}
  end

  defp normalize_domain(domain, types) when is_map(domain) do
    definitions = types["EIP712Domain"]

    with true <-
           Enum.all?(definitions, fn %{"name" => name, "type" => type} ->
             @domain_types[name] == type
           end),
         true <- Enum.all?(Map.keys(domain), &Map.has_key?(@domain_types, &1)),
         {:ok, domain} <- normalize_struct(domain, definitions, types, 0) do
      {:ok, domain}
    else
      _other -> {:error, :invalid_params}
    end
  end

  defp normalize_domain(_domain, _types), do: {:error, :invalid_params}

  defp normalize_struct(value, fields, types, depth)
       when is_map(value) and is_list(fields) and depth <= @max_depth do
    field_names = Enum.map(fields, & &1["name"])

    with true <- Enum.sort(Map.keys(value)) == Enum.sort(field_names) do
      Enum.reduce_while(fields, {:ok, %{}}, fn %{"name" => name, "type" => type},
                                               {:ok, normalized} ->
        case normalize_typed_value(value[name], type, types, depth + 1) do
          {:ok, value} -> {:cont, {:ok, Map.put(normalized, name, value)}}
          _error -> {:halt, {:error, :invalid_params}}
        end
      end)
    else
      _other -> {:error, :invalid_params}
    end
  end

  defp normalize_struct(_value, _fields, _types, _depth), do: {:error, :invalid_params}

  defp normalize_typed_value(value, type, types, depth) when depth <= @max_depth do
    with {:ok, base, dimensions} <- parse_type(type, types) do
      normalize_typed_dimensions(value, base, Enum.reverse(dimensions), types, depth)
    end
  end

  defp normalize_typed_value(_value, _type, _types, _depth), do: {:error, :invalid_params}

  defp normalize_typed_dimensions(value, base, [dimension | remaining], types, depth)
       when is_list(value) and length(value) <= @max_collection do
    with true <- dimension == :dynamic or length(value) == dimension do
      Enum.reduce_while(value, {:ok, []}, fn item, {:ok, normalized} ->
        case normalize_typed_dimensions(item, base, remaining, types, depth + 1) do
          {:ok, item} -> {:cont, {:ok, [item | normalized]}}
          _error -> {:halt, {:error, :invalid_params}}
        end
      end)
      |> case do
        {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
        error -> error
      end
    else
      _other -> {:error, :invalid_params}
    end
  end

  defp normalize_typed_dimensions(value, base, [], types, depth),
    do: normalize_typed_primitive(value, base, types, depth)

  defp normalize_typed_dimensions(_value, _base, _dimensions, _types, _depth),
    do: {:error, :invalid_params}

  defp normalize_typed_primitive(value, "address", _types, _depth), do: normalize_address(value)

  defp normalize_typed_primitive(value, "bool", _types, _depth) when is_boolean(value),
    do: {:ok, value}

  defp normalize_typed_primitive(value, "string", _types, _depth)
       when is_binary(value) and byte_size(value) <= @max_string_bytes,
       do: {:ok, value}

  defp normalize_typed_primitive(value, "bytes", _types, _depth),
    do: normalize_data(value, div(@max_string_bytes - 2, 2))

  defp normalize_typed_primitive(value, "bytes" <> encoded_size, _types, _depth) do
    with {size, ""} <- Integer.parse(encoded_size),
         true <- size in 1..32 do
      case normalize_fixed_data(value, size) do
        {:ok, value} -> {:ok, value}
        _error -> {:error, :invalid_params}
      end
    else
      _other -> {:error, :invalid_params}
    end
  end

  defp normalize_typed_primitive(value, "uint" <> encoded_bits, _types, _depth) do
    with {:ok, bits} <- integer_bits(encoded_bits),
         {:ok, integer} <- typed_integer(value, false),
         true <- integer < 1 <<< bits do
      {:ok, Integer.to_string(integer)}
    else
      _other -> {:error, :invalid_params}
    end
  end

  defp normalize_typed_primitive(value, "int" <> encoded_bits, _types, _depth) do
    with {:ok, bits} <- integer_bits(encoded_bits),
         {:ok, integer} <- typed_integer(value, true),
         limit <- 1 <<< (bits - 1),
         true <- integer >= -limit and integer < limit do
      {:ok, Integer.to_string(integer)}
    else
      _other -> {:error, :invalid_params}
    end
  end

  defp normalize_typed_primitive(value, custom_type, types, depth) do
    case types do
      %{^custom_type => fields} -> normalize_struct(value, fields, types, depth + 1)
      _types -> {:error, :invalid_params}
    end
  end

  defp parse_type(type, types) when is_binary(type) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)(.*)$/, type) do
      [_, base, suffix] ->
        with true <- primitive_type?(base) or Map.has_key?(types, base),
             {:ok, dimensions} <- parse_dimensions(suffix) do
          {:ok, base, dimensions}
        else
          _other -> {:error, :invalid_type}
        end

      _other ->
        {:error, :invalid_type}
    end
  end

  defp parse_type(_type, _types), do: {:error, :invalid_type}

  defp parse_dimensions(""), do: {:ok, []}

  defp parse_dimensions(suffix) do
    dimensions = Regex.scan(~r/\[([0-9]*)\]/, suffix)

    with true <- length(dimensions) in 1..4,
         true <- Enum.map_join(dimensions, "", &hd/1) == suffix do
      Enum.reduce_while(dimensions, {:ok, []}, fn
        [_whole, ""], {:ok, parsed} ->
          {:cont, {:ok, [:dynamic | parsed]}}

        [_whole, encoded], {:ok, parsed} ->
          case Integer.parse(encoded) do
            {size, ""} when size in 1..@max_collection ->
              {:cont, {:ok, [size | parsed]}}

            _other ->
              {:halt, {:error, :invalid_type}}
          end
      end)
      |> case do
        {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
        error -> error
      end
    else
      _other -> {:error, :invalid_type}
    end
  end

  defp primitive_type?(type) when type in ["address", "bool", "string", "bytes"], do: true

  defp primitive_type?("bytes" <> size), do: valid_integer_suffix?(size, 1, 32, 1)
  defp primitive_type?("uint" <> bits), do: valid_integer_suffix?(bits, 8, 256, 8)
  defp primitive_type?("int" <> bits), do: valid_integer_suffix?(bits, 8, 256, 8)
  defp primitive_type?(_type), do: false

  defp valid_integer_suffix?("", minimum, maximum, _step), do: maximum >= minimum

  defp valid_integer_suffix?(encoded, minimum, maximum, step) do
    case Integer.parse(encoded) do
      {value, ""} -> value in minimum..maximum and rem(value, step) == 0
      _other -> false
    end
  end

  defp integer_bits(""), do: {:ok, 256}

  defp integer_bits(encoded) do
    case Integer.parse(encoded) do
      {bits, ""} when bits in 8..256 and rem(bits, 8) == 0 -> {:ok, bits}
      _other -> {:error, :invalid_params}
    end
  end

  defp typed_integer(value, signed?) when is_integer(value) do
    if abs(value) <= 9_007_199_254_740_991 and (signed? or value >= 0),
      do: {:ok, value},
      else: {:error, :invalid_params}
  end

  defp typed_integer(value, signed?) when is_binary(value) do
    cond do
      Regex.match?(@quantity, value) and byte_size(value) <= 66 ->
        {:ok, quantity_integer(value)}

      byte_size(value) <= 79 and
          Regex.match?(if(signed?, do: @signed_decimal, else: @decimal), value) ->
        case Integer.parse(value) do
          {integer, ""} when signed? or integer >= 0 -> {:ok, integer}
          _other -> {:error, :invalid_params}
        end

      true ->
        {:error, :invalid_params}
    end
  end

  defp typed_integer(_value, _signed?), do: {:error, :invalid_params}

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp valid_identifier?(value), do: is_binary(value) and Regex.match?(@identifier, value)

  defp display_chain_id(nil), do: nil
  defp display_chain_id(value) when is_binary(value), do: value
  defp display_chain_id(value) when is_integer(value), do: Integer.to_string(value)
end
