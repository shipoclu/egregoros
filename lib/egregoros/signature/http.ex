defmodule Egregoros.Signature.HTTP do
  @behaviour Egregoros.Signature

  alias Egregoros.Config
  alias Egregoros.HTTPDate
  alias Egregoros.MiniApps.ActorActivation
  alias Egregoros.PublicHostPolicy
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.ClientIP

  @default_headers ["(request-target)", "host", "date", "digest", "content-length"]
  @signature_param_names MapSet.new(["keyId", "algorithm", "headers", "signature"])
  @max_request_headers 128
  @max_header_value_bytes 16_384
  @max_total_header_bytes 65_536

  @impl true
  def verify_request(conn) do
    with {:ok, headers} <- normalize_headers(conn.req_headers),
         {:ok, request_host} <- verified_request_host(conn),
         {:ok, key_id, signature, headers_param} <- parse_signature(headers),
         signer_ap_id when is_binary(signer_ap_id) <- signer_ap_id_from_key_id(key_id),
         {:ok, key} <- public_key_for_key_id(key_id),
         :ok <- ActorActivation.authorize_signing_key(signer_ap_id, key_id, key),
         {:ok, method} <- method_atom(conn.method),
         :ok <- validate_date(headers, headers_param),
         :ok <- validate_required_signature_headers(headers_param, method),
         :ok <- validate_digest(headers, conn, headers_param) do
      headers_param = normalize_header_names(headers_param)
      headers = augment_headers(headers, conn, headers_param, request_host)

      request_targets(conn, method)
      |> Enum.any?(fn request_target ->
        signature_string = signature_string(request_target, headers, headers_param)
        verify_rsa(signature, signature_string, key)
      end)
      |> case do
        true -> {:ok, signer_ap_id}
        false -> {:error, :invalid_signature}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_signature}
    end
  end

  def sign_request(%User{} = user, method, url, body, headers_param \\ @default_headers)
      when is_binary(method) and is_binary(url) and is_binary(body) do
    headers_param = normalize_header_names(headers_param)

    with {:ok, method} <- method_atom(method),
         {:ok, private_key} <- private_key_from_user(user) do
      uri = URI.parse(url)
      request_target = method <> " " <> request_path_with_query(uri)
      date = signed_date()
      host = host_header_for_uri(uri)
      content_length = Integer.to_string(byte_size(body))
      digest = digest_for(body)

      headers =
        %{
          "date" => date,
          "host" => host,
          "content-length" => content_length,
          "digest" => digest
        }

      signature_string = signature_string(request_target, headers, headers_param)
      signature = :public_key.sign(signature_string, :sha256, private_key) |> Base.encode64()

      signature_params =
        "keyId=\"#{user.ap_id}#main-key\"," <>
          "algorithm=\"rsa-sha256\"," <>
          "headers=\"#{Enum.join(headers_param, " ")}\"," <>
          "signature=\"#{signature}\""

      {:ok,
       %{
         signature: signature_params,
         authorization: "Signature " <> signature_params,
         date: date,
         digest: digest,
         content_length: content_length,
         host: host,
         headers: headers_param
       }}
    end
  end

  defp normalize_headers(headers)
       when is_list(headers) and length(headers) <= @max_request_headers do
    headers
    |> Enum.reduce_while({:ok, %{}, 0}, fn
      {key, value}, {:ok, normalized, total_bytes}
      when is_binary(key) and is_binary(value) ->
        key = String.downcase(key)
        entry_bytes = byte_size(key) + byte_size(value)

        if key != "" and byte_size(value) <= @max_header_value_bytes and
             total_bytes + entry_bytes <= @max_total_header_bytes and
             not Map.has_key?(normalized, key) do
          {:cont, {:ok, Map.put(normalized, key, value), total_bytes + entry_bytes}}
        else
          {:halt, {:error, :invalid_signature}}
        end

      _header, _acc ->
        {:halt, {:error, :invalid_signature}}
    end)
    |> case do
      {:ok, normalized, _total_bytes} -> {:ok, normalized}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_headers(_headers), do: {:error, :invalid_signature}

  defp parse_signature(headers) do
    case {Map.get(headers, "signature"), Map.get(headers, "authorization")} do
      {signature, nil} when is_binary(signature) -> parse_signature_value(signature)
      {nil, authorization} when is_binary(authorization) -> parse_signature_value(authorization)
      {nil, nil} -> {:error, :missing_signature}
      _ -> {:error, :invalid_signature}
    end
  end

  defp parse_signature_value("Signature " <> rest), do: parse_signature_params(rest)
  defp parse_signature_value(rest) when is_binary(rest), do: parse_signature_params(rest)
  defp parse_signature_value(_), do: {:error, :invalid_signature}

  defp parse_signature_params(rest)
       when is_binary(rest) and byte_size(rest) in 1..@max_header_value_bytes do
    with {:ok, params} <- strict_signature_params(rest),
         :ok <- validate_signature_algorithm(Map.get(params, "algorithm")),
         key_id when is_binary(key_id) <- Map.get(params, "keyId"),
         true <- byte_size(key_id) in 1..2_048,
         signature_b64 when is_binary(signature_b64) <- Map.get(params, "signature"),
         {:ok, decoded} <- Base.decode64(signature_b64),
         true <- byte_size(decoded) in 1..2_048,
         {:ok, headers_param} <- signature_header_names(Map.get(params, "headers")) do
      {:ok, key_id, decoded, headers_param}
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp parse_signature_params(_rest), do: {:error, :invalid_signature}

  defp strict_signature_params(rest) do
    rest
    |> String.split(",")
    |> Enum.reduce_while({:ok, %{}}, fn part, {:ok, params} ->
      case Regex.run(~r/\A([A-Za-z][A-Za-z0-9_-]*)="([^"\\]*)"\z/, String.trim(part)) do
        [_, key, value] ->
          if MapSet.member?(@signature_param_names, key) and not Map.has_key?(params, key) do
            {:cont, {:ok, Map.put(params, key, value)}}
          else
            {:halt, {:error, :invalid_signature}}
          end

        _ ->
          {:halt, {:error, :invalid_signature}}
      end
    end)
  end

  defp validate_signature_algorithm(nil), do: :ok

  defp validate_signature_algorithm(algorithm) when is_binary(algorithm) do
    if String.downcase(algorithm) in ["rsa-sha256", "hs2019"],
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp validate_signature_algorithm(_algorithm), do: {:error, :invalid_signature}

  defp signature_header_names(nil), do: {:ok, ["(request-target)", "date"]}

  defp signature_header_names(value) when is_binary(value) and byte_size(value) in 1..2_048 do
    names = value |> String.split() |> Enum.map(&String.downcase/1)

    if names != [] and length(names) <= 32 and length(names) == length(Enum.uniq(names)) and
         Enum.all?(names, &valid_signature_header_name?/1) do
      {:ok, names}
    else
      {:error, :invalid_signature}
    end
  end

  defp signature_header_names(_value), do: {:error, :invalid_signature}

  defp valid_signature_header_name?(name)
       when name in ["(request-target)", "@request-target"],
       do: true

  defp valid_signature_header_name?(name) when is_binary(name),
    do: String.match?(name, ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/)

  defp valid_signature_header_name?(_name), do: false

  defp public_key_for_key_id(key_id) when is_binary(key_id) do
    ap_id = actor_ap_id_from_key_id(key_id)

    case ActorActivation.pinned_signing_key(ap_id, key_id) do
      {:ok, key} -> {:ok, key}
      :not_declared -> public_key_for_federated_actor(ap_id)
      {:error, _reason} = error -> error
    end
  end

  defp public_key_for_key_id(_), do: {:error, :invalid_signature}

  defp public_key_for_federated_actor(ap_id) when is_binary(ap_id) do
    case Users.get_by_ap_id(ap_id) do
      %{} = user ->
        case :public_key.pem_decode(user.public_key) do
          [entry] ->
            try do
              {:ok, :public_key.pem_entry_decode(entry)}
            rescue
              _ -> {:error, :unknown_key}
            end

          _ ->
            {:error, :unknown_key}
        end

      _ ->
        fetch_public_key_for_actor(ap_id)
    end
  end

  defp public_key_for_federated_actor(_ap_id), do: {:error, :unknown_key}

  defp signer_ap_id_from_key_id(key_id) when is_binary(key_id) do
    case actor_ap_id_from_key_id(key_id) do
      ap_id when is_binary(ap_id) and ap_id != "" -> ap_id
      _ -> nil
    end
  end

  defp signer_ap_id_from_key_id(_), do: nil

  defp actor_ap_id_from_key_id(key_id) when is_binary(key_id) do
    key_id
    |> String.split("#", parts: 2)
    |> List.first()
    |> String.trim()
    |> case do
      "" -> nil
      ap_id -> strip_known_key_suffix(ap_id)
    end
  end

  defp actor_ap_id_from_key_id(_key_id), do: nil

  defp strip_known_key_suffix(ap_id) when is_binary(ap_id) do
    if String.ends_with?(ap_id, "/main-key") do
      String.trim_trailing(ap_id, "/main-key")
    else
      ap_id
    end
  end

  defp fetch_public_key_for_actor(ap_id) when is_binary(ap_id) do
    with {:ok, user} <- Egregoros.Federation.Actor.fetch_and_store(ap_id),
         [entry] <- :public_key.pem_decode(user.public_key) do
      {:ok, :public_key.pem_entry_decode(entry)}
    else
      {:error, _} = error -> error
      _ -> {:error, :unknown_key}
    end
  end

  defp signature_string(request_target, headers, headers_param) do
    headers_param
    |> Enum.map(fn
      "(request-target)" -> "(request-target): #{request_target}"
      "@request-target" -> "@request-target: #{request_target}"
      header -> "#{header}: #{Map.get(headers, header, "")}"
    end)
    |> Enum.join("\n")
  end

  defp verify_rsa(signature, data, public_key) do
    :public_key.verify(data, :sha256, signature, public_key)
  end

  defp request_targets(conn, method) do
    base = method <> " " <> conn.request_path

    case conn.query_string do
      "" -> [base]
      nil -> [base]
      qs -> [base, base <> "?" <> qs]
    end
  end

  defp method_atom(method) when is_binary(method) do
    case String.downcase(method) do
      "get" -> {:ok, "get"}
      "post" -> {:ok, "post"}
      "put" -> {:ok, "put"}
      "patch" -> {:ok, "patch"}
      "delete" -> {:ok, "delete"}
      "head" -> {:ok, "head"}
      "options" -> {:ok, "options"}
      _ -> {:error, :invalid_method}
    end
  end

  defp validate_date(headers, headers_param) do
    headers_param = normalize_header_names(headers_param)

    if "date" in headers_param do
      case Map.get(headers, "date") do
        nil -> {:error, :missing_date}
        date -> check_date_skew(date)
      end
    else
      {:error, :missing_date}
    end
  end

  defp check_date_skew(date_header) do
    with {:ok, signed_at} <- parse_http_date(date_header) do
      diff = DateTime.diff(DateTime.utc_now(), signed_at) |> abs()

      if diff <= max_skew_seconds() do
        :ok
      else
        {:error, :date_skew}
      end
    end
  end

  defp validate_digest(headers, conn, headers_param) do
    headers_param = normalize_header_names(headers_param)

    if "digest" in headers_param do
      with digest_header when is_binary(digest_header) <- Map.get(headers, "digest"),
           body when is_binary(body) <- raw_body(conn),
           {:ok, expected_digest} <- sha256_digest_value(digest_header) do
        actual_digest = :crypto.hash(:sha256, body) |> Base.encode64()

        if expected_digest == actual_digest do
          :ok
        else
          {:error, :digest_mismatch}
        end
      else
        nil -> {:error, :missing_digest}
        {:error, _} = error -> error
        _ -> {:error, :invalid_digest}
      end
    else
      :ok
    end
  end

  defp sha256_digest_value(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value({:error, :invalid_digest}, fn part ->
      case String.split(part, "=", parts: 2) do
        [algorithm, digest] ->
          algorithm = algorithm |> String.trim() |> String.downcase()
          digest = String.trim(digest)

          if algorithm == "sha-256" and digest != "" do
            {:ok, digest}
          else
            nil
          end

        _ ->
          nil
      end
    end)
  end

  defp sha256_digest_value(_value), do: {:error, :invalid_digest}

  defp parse_http_date(date_header) when is_binary(date_header) do
    HTTPDate.parse_rfc1123(date_header)
  end

  defp max_skew_seconds do
    Config.get(:signature_skew_seconds, 300)
  end

  defp validate_required_signature_headers(headers_param, method) when is_list(headers_param) do
    headers_param = normalize_header_names(headers_param)

    request_target_header? =
      "(request-target)" in headers_param or "@request-target" in headers_param

    required_headers = required_signature_headers_for_method(method)
    missing = Enum.reject(required_headers, &(&1 in headers_param))

    if request_target_header? and missing == [] do
      :ok
    else
      {:error, :missing_required_signature_headers}
    end
  end

  defp validate_required_signature_headers(_headers_param, _method), do: :ok

  defp required_signature_headers_for_method(method) when method in ["post", "put", "patch"] do
    ["host", "date", "digest"]
  end

  defp required_signature_headers_for_method(_method) do
    ["host", "date"]
  end

  defp normalize_header_names(headers_param) do
    headers_param
    |> Enum.map(&String.downcase/1)
  end

  defp augment_headers(headers, conn, headers_param, request_host) do
    headers_param_set = MapSet.new(headers_param)

    headers
    |> maybe_put_host(request_host, headers_param_set)
    |> maybe_put_content_length(conn, headers_param_set)
    |> maybe_put_digest(conn, headers_param_set)
  end

  defp maybe_put_host(headers, request_host, headers_param_set) do
    if MapSet.member?(headers_param_set, "host") do
      Map.put(headers, "host", request_host)
    else
      headers
    end
  end

  defp maybe_put_content_length(headers, conn, headers_param_set) do
    if MapSet.member?(headers_param_set, "content-length") and is_binary(raw_body(conn)) and
         not Map.has_key?(headers, "content-length") do
      Map.put(headers, "content-length", Integer.to_string(byte_size(raw_body(conn))))
    else
      headers
    end
  end

  defp maybe_put_digest(headers, conn, headers_param_set) do
    if MapSet.member?(headers_param_set, "digest") and is_binary(raw_body(conn)) and
         not Map.has_key?(headers, "digest") do
      Map.put(headers, "digest", digest_for(raw_body(conn)))
    else
      headers
    end
  end

  defp raw_body(conn) do
    Map.get(conn.assigns, :raw_body)
  end

  defp digest_for(body) do
    "SHA-256=" <> (:crypto.hash(:sha256, body) |> Base.encode64())
  end

  defp verified_request_host(conn) do
    with {:ok, host, scheme, port} <- effective_authority(conn),
         {:ok, normalized_host} <- PublicHostPolicy.normalize_host(host),
         true <- PublicHostPolicy.public_host?(normalized_host) do
      if is_nil(port) or port == default_port_for_scheme(scheme) do
        {:ok, normalized_host}
      else
        {:ok, "#{normalized_host}:#{port}"}
      end
    else
      _ -> {:error, :invalid_host}
    end
  end

  defp effective_authority(conn) do
    if ClientIP.trusted_proxy?(conn) do
      with {:ok, forwarded_host} <- optional_forwarded_header(conn, "x-forwarded-host"),
           {:ok, forwarded_proto} <- optional_forwarded_header(conn, "x-forwarded-proto"),
           {:ok, forwarded_port} <- optional_forwarded_header(conn, "x-forwarded-port"),
           {:ok, scheme} <- forwarded_scheme(forwarded_proto, conn.scheme),
           {:ok, port} <-
             authority_port(forwarded_host, forwarded_port, scheme, forwarded_proto, conn.port) do
        {:ok, forwarded_host || conn.host, scheme, port}
      end
    else
      {:ok, conn.host, conn.scheme, conn.port}
    end
  end

  defp optional_forwarded_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [] ->
        {:ok, nil}

      [value] when is_binary(value) ->
        value = String.trim(value)

        if value != "" and not String.contains?(value, ","),
          do: {:ok, value},
          else: {:error, :invalid_host}

      _ ->
        {:error, :invalid_host}
    end
  end

  defp forwarded_scheme(nil, fallback), do: {:ok, fallback}
  defp forwarded_scheme("https", _fallback), do: {:ok, :https}
  defp forwarded_scheme("http", _fallback), do: {:ok, :http}
  defp forwarded_scheme(_value, _fallback), do: {:error, :invalid_host}

  defp authority_port(forwarded_host, forwarded_port, scheme, forwarded_proto, direct_port) do
    case parse_forwarded_port(forwarded_port) do
      {:ok, port} ->
        {:ok, port}

      :error when not is_nil(forwarded_port) ->
        {:error, :invalid_host}

      :error ->
        host_port = explicit_host_port(forwarded_host)

        cond do
          is_integer(host_port) -> {:ok, host_port}
          is_binary(forwarded_proto) -> {:ok, default_port_for_scheme(scheme)}
          true -> {:ok, direct_port}
        end
    end
  end

  defp explicit_host_port(nil), do: nil

  defp explicit_host_port(host) do
    case URI.parse("https://" <> host) do
      %URI{authority: authority, port: port} when is_binary(authority) ->
        if String.contains?(authority, ":"), do: port

      _ ->
        nil
    end
  end

  defp parse_forwarded_port(nil), do: :error

  defp parse_forwarded_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _ -> :error
    end
  end

  defp default_port_for_scheme(:https), do: 443
  defp default_port_for_scheme(_), do: 80

  defp host_header_for_uri(%URI{} = uri) do
    default_port = URI.default_port(uri.scheme)

    if uri.port in [nil, default_port] do
      uri.host
    else
      "#{uri.host}:#{uri.port}"
    end
  end

  defp request_path_with_query(%URI{} = uri) do
    path =
      case uri.path do
        nil -> "/"
        "" -> "/"
        value -> value
      end

    case uri.query do
      nil -> path
      "" -> path
      query -> path <> "?" <> query
    end
  end

  defp signed_date do
    HTTPDate.format_rfc1123(DateTime.utc_now())
  end

  defp private_key_from_user(%User{private_key: pem}) when is_binary(pem) do
    [entry] = :public_key.pem_decode(pem)
    {:ok, :public_key.pem_entry_decode(entry)}
  end
end
