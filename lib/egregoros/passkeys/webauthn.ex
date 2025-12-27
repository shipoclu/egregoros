defmodule Egregoros.Passkeys.WebAuthn do
  @moduledoc false

  import Bitwise

  alias Egregoros.CBOR
  alias EgregorosWeb.Endpoint

  @timeout_ms 60_000

  @type error ::
          :invalid_payload
          | :challenge_mismatch
          | :origin_mismatch
          | :rp_id_mismatch
          | :invalid_signature
          | :invalid_public_key
          | :invalid_attestation
          | :invalid_assertion

  def rp_id do
    Endpoint.url()
    |> URI.parse()
    |> Map.get(:host)
    |> case do
      host when is_binary(host) and host != "" -> host
      _ -> "localhost"
    end
  end

  def origin do
    Endpoint.url()
  end

  def registration_options(nickname, challenge, user_handle)
      when is_binary(nickname) and is_binary(challenge) and is_binary(user_handle) do
    %{
      "challenge" => b64url(challenge),
      "rp" => %{"name" => "Egregoros", "id" => rp_id()},
      "user" => %{
        "id" => b64url(user_handle),
        "name" => nickname,
        "displayName" => nickname
      },
      "pubKeyCredParams" => [%{"type" => "public-key", "alg" => -7}],
      "timeout" => @timeout_ms,
      "attestation" => "none",
      "authenticatorSelection" => %{
        "residentKey" => "preferred",
        "userVerification" => "required"
      }
    }
  end

  def authentication_options(credentials, challenge)
      when is_list(credentials) and is_binary(challenge) do
    allow_credentials =
      credentials
      |> Enum.flat_map(fn
        %{credential_id: id} when is_binary(id) and id != "" ->
          [%{"type" => "public-key", "id" => b64url(id)}]

        _ ->
          []
      end)

    %{
      "challenge" => b64url(challenge),
      "timeout" => @timeout_ms,
      "rpId" => rp_id(),
      "allowCredentials" => allow_credentials,
      "userVerification" => "required"
    }
  end

  def verify_attestation(%{} = credential, expected_challenge_b64)
      when is_binary(expected_challenge_b64) do
    with {:ok, raw_id} <- fetch_b64(credential, "rawId"),
         {:ok, attestation_object} <- fetch_b64_response(credential, "attestationObject"),
         {:ok, client_data_json} <- fetch_b64_response(credential, "clientDataJSON"),
         :ok <- verify_client_data(client_data_json, "webauthn.create", expected_challenge_b64),
         {:ok, %{credential_id: credential_id, public_key: public_key, sign_count: sign_count}} <-
           parse_attestation(attestation_object),
         true <- credential_id == raw_id do
      {:ok, %{credential_id: credential_id, public_key: public_key, sign_count: sign_count}}
    else
      false -> {:error, :invalid_attestation}
      {:error, _} = error -> error
      _ -> {:error, :invalid_attestation}
    end
  end

  def verify_assertion(%{} = credential, expected_challenge_b64, stored_public_key, opts \\ [])
      when is_binary(expected_challenge_b64) and is_binary(stored_public_key) and is_list(opts) do
    require_uv? = Keyword.get(opts, :require_user_verification?, true)

    with {:ok, raw_id} <- fetch_b64(credential, "rawId"),
         {:ok, authenticator_data} <- fetch_b64_response(credential, "authenticatorData"),
         {:ok, client_data_json} <- fetch_b64_response(credential, "clientDataJSON"),
         {:ok, signature} <- fetch_b64_response(credential, "signature"),
         :ok <- verify_client_data(client_data_json, "webauthn.get", expected_challenge_b64),
         :ok <- verify_authenticator_data(authenticator_data, require_uv?),
         :ok <-
           verify_signature(authenticator_data, client_data_json, signature, stored_public_key),
         {:ok, sign_count} <- parse_sign_count(authenticator_data) do
      {:ok, %{credential_id: raw_id, sign_count: sign_count}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_assertion}
    end
  end

  defp verify_client_data(client_data_json, expected_type, expected_challenge_b64)
       when is_binary(client_data_json) and is_binary(expected_type) and
              is_binary(expected_challenge_b64) do
    expected_origin = origin()

    with {:ok, %{} = decoded} <- Jason.decode(client_data_json),
         ^expected_type <- Map.get(decoded, "type"),
         ^expected_challenge_b64 <- Map.get(decoded, "challenge"),
         ^expected_origin <- Map.get(decoded, "origin") do
      :ok
    else
      {:error, _} -> {:error, :invalid_payload}
      _ -> {:error, :challenge_mismatch}
    end
  end

  defp parse_attestation(attestation_object) when is_binary(attestation_object) do
    with {:ok, %{} = decoded} <- CBOR.decode(attestation_object),
         auth_data when is_binary(auth_data) <- Map.get(decoded, "authData"),
         {:ok, rp_id_hash, flags, sign_count, rest} <- split_auth_data(auth_data),
         :ok <- verify_rp_id_hash(rp_id_hash),
         :ok <- verify_flags(flags, require_uv?: true, require_attested_data?: true),
         {:ok, %{credential_id: credential_id, public_key: public_key}} <-
           parse_credential_data(rest) do
      {:ok, %{credential_id: credential_id, public_key: public_key, sign_count: sign_count}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_attestation}
    end
  end

  defp split_auth_data(<<rp_id_hash::binary-size(32), flags::8, sign_count::32, rest::binary>>) do
    {:ok, rp_id_hash, flags, sign_count, rest}
  end

  defp split_auth_data(_), do: {:error, :invalid_attestation}

  defp verify_rp_id_hash(rp_id_hash) when is_binary(rp_id_hash) do
    expected = :crypto.hash(:sha256, rp_id())
    if Plug.Crypto.secure_compare(rp_id_hash, expected), do: :ok, else: {:error, :rp_id_mismatch}
  end

  defp verify_rp_id_hash(_), do: {:error, :rp_id_mismatch}

  defp verify_authenticator_data(authenticator_data, require_uv?)
       when is_binary(authenticator_data) do
    with {:ok, rp_id_hash, flags, _sign_count, _rest} <- split_auth_data(authenticator_data),
         :ok <- verify_rp_id_hash(rp_id_hash),
         :ok <- verify_flags(flags, require_uv?: require_uv?, require_attested_data?: false) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_assertion}
    end
  end

  defp verify_signature(authenticator_data, client_data_json, signature, public_key)
       when is_binary(authenticator_data) and is_binary(client_data_json) and is_binary(signature) and
              is_binary(public_key) do
    signed =
      authenticator_data <>
        :crypto.hash(:sha256, client_data_json)

    if :crypto.verify(:ecdsa, :sha256, signed, signature, [public_key, :prime256v1]) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp verify_signature(_authenticator_data, _client_data_json, _signature, _public_key),
    do: {:error, :invalid_signature}

  defp parse_sign_count(
         <<_rp_id_hash::binary-size(32), _flags::8, sign_count::32, _rest::binary>>
       ),
       do: {:ok, sign_count}

  defp parse_sign_count(_), do: {:error, :invalid_assertion}

  defp verify_flags(flags, opts) when is_integer(flags) and is_list(opts) do
    require_uv? = Keyword.get(opts, :require_uv?, false)
    require_attested_data? = Keyword.get(opts, :require_attested_data?, false)

    user_present? = (flags &&& 0x01) != 0
    user_verified? = (flags &&& 0x04) != 0
    attested_data? = (flags &&& 0x40) != 0

    cond do
      not user_present? -> {:error, :invalid_payload}
      require_uv? and not user_verified? -> {:error, :invalid_payload}
      require_attested_data? and not attested_data? -> {:error, :invalid_payload}
      true -> :ok
    end
  end

  defp verify_flags(_flags, _opts), do: {:error, :invalid_payload}

  defp parse_credential_data(<<_aaguid::binary-size(16), cred_len::16, rest::binary>>)
       when is_integer(cred_len) and cred_len > 0 do
    with true <- byte_size(rest) >= cred_len,
         <<credential_id::binary-size(cred_len), cose_key::binary>> <- rest,
         {:ok, cose_map, _rest2} <- CBOR.decode_next(cose_key),
         {:ok, public_key} <- cose_public_key(cose_map) do
      {:ok, %{credential_id: credential_id, public_key: public_key}}
    else
      false -> {:error, :invalid_public_key}
      _ -> {:error, :invalid_public_key}
    end
  end

  defp parse_credential_data(_), do: {:error, :invalid_public_key}

  defp cose_public_key(%{} = cose) do
    with 2 <- Map.get(cose, 1),
         1 <- Map.get(cose, -1),
         x when is_binary(x) and byte_size(x) == 32 <- Map.get(cose, -2),
         y when is_binary(y) and byte_size(y) == 32 <- Map.get(cose, -3) do
      {:ok, <<4, x::binary, y::binary>>}
    else
      _ -> {:error, :invalid_public_key}
    end
  end

  defp cose_public_key(_), do: {:error, :invalid_public_key}

  defp fetch_b64(%{} = credential, key) when is_binary(key) do
    case Map.get(credential, key) do
      value when is_binary(value) ->
        case Base.url_decode64(value, padding: false) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, :invalid_payload}
        end

      _ ->
        {:error, :invalid_payload}
    end
  end

  defp fetch_b64(_credential, _key), do: {:error, :invalid_payload}

  defp fetch_b64_response(%{"response" => %{} = response}, key) when is_binary(key) do
    fetch_b64(response, key)
  end

  defp fetch_b64_response(_credential, _key), do: {:error, :invalid_payload}

  defp b64url(value) when is_binary(value) do
    Base.url_encode64(value, padding: false)
  end
end
