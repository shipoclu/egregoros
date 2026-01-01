defmodule Egregoros.Passkeys.WebAuthnTest do
  use ExUnit.Case, async: true

  alias Egregoros.CBOR
  alias Egregoros.Passkeys.WebAuthn

  defp b64url(value) when is_binary(value) do
    Base.url_encode64(value, padding: false)
  end

  defp client_data_json(type, challenge_b64) when is_binary(type) and is_binary(challenge_b64) do
    Jason.encode!(%{
      "type" => type,
      "challenge" => challenge_b64,
      "origin" => WebAuthn.origin()
    })
  end

  defp authenticator_data(flags, sign_count)
       when is_integer(flags) and is_integer(sign_count) and sign_count >= 0 do
    rp_id_hash = :crypto.hash(:sha256, WebAuthn.rp_id())
    rp_id_hash <> <<flags::8, sign_count::32>>
  end

  defp valid_attestation_object(credential_id) when is_binary(credential_id) and credential_id != "" do
    flags = 0x01 + 0x04 + 0x40
    sign_count = 0

    x = :crypto.strong_rand_bytes(32)
    y = :crypto.strong_rand_bytes(32)

    cose_key =
      %{
        1 => 2,
        -1 => 1,
        -2 => x,
        -3 => y
      }
      |> CBOR.encode()

    rest =
      <<0::128, byte_size(credential_id)::16, credential_id::binary, cose_key::binary>>

    auth_data = authenticator_data(flags, sign_count) <> rest

    %{"authData" => auth_data}
    |> CBOR.encode()
  end

  test "registration_options/3 encodes challenge and user handle as base64url" do
    options = WebAuthn.registration_options("alice", "challenge", "user-handle")

    assert options["challenge"] == b64url("challenge")
    assert options["user"]["id"] == b64url("user-handle")
    assert options["rp"]["id"] == WebAuthn.rp_id()
    assert options["timeout"] == 60_000
  end

  test "authentication_options/2 filters invalid credential ids" do
    options =
      WebAuthn.authentication_options(
        [
          %{credential_id: "cred-1"},
          %{credential_id: ""},
          %{}
        ],
        "challenge"
      )

    assert options["challenge"] == b64url("challenge")
    assert options["rpId"] == WebAuthn.rp_id()

    assert options["allowCredentials"] == [
             %{"type" => "public-key", "id" => b64url("cred-1")}
           ]
  end

  test "verify_attestation/2 returns ok for a minimal valid attestationObject" do
    credential_id = "credential-id"
    raw_id_b64 = b64url(credential_id)
    challenge_b64 = b64url("challenge")

    client_data = client_data_json("webauthn.create", challenge_b64)
    attestation_object = valid_attestation_object(credential_id)

    credential = %{
      "rawId" => raw_id_b64,
      "response" => %{
        "clientDataJSON" => b64url(client_data),
        "attestationObject" => b64url(attestation_object)
      }
    }

    assert {:ok, result} = WebAuthn.verify_attestation(credential, challenge_b64)
    assert result.credential_id == credential_id
    assert is_binary(result.public_key) and byte_size(result.public_key) == 65
    assert result.sign_count == 0
  end

  test "verify_attestation/2 returns challenge_mismatch when the client challenge is wrong" do
    credential_id = "credential-id"
    raw_id_b64 = b64url(credential_id)

    expected_challenge_b64 = b64url("challenge")
    wrong_client_data = client_data_json("webauthn.create", b64url("wrong"))

    credential = %{
      "rawId" => raw_id_b64,
      "response" => %{
        "clientDataJSON" => b64url(wrong_client_data),
        "attestationObject" => b64url("not-used")
      }
    }

    assert {:error, :challenge_mismatch} =
             WebAuthn.verify_attestation(credential, expected_challenge_b64)
  end

  test "verify_assertion/4 returns ok for a valid signature and rpId hash" do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)
    raw_id = "credential-id"

    flags = 0x01 + 0x04
    sign_count = 7
    authenticator_data = authenticator_data(flags, sign_count)

    challenge_b64 = b64url("challenge")
    client_data = client_data_json("webauthn.get", challenge_b64)

    signed = authenticator_data <> :crypto.hash(:sha256, client_data)
    signature = :crypto.sign(:ecdsa, :sha256, signed, [private_key, :prime256v1])

    credential = %{
      "rawId" => b64url(raw_id),
      "response" => %{
        "authenticatorData" => b64url(authenticator_data),
        "clientDataJSON" => b64url(client_data),
        "signature" => b64url(signature)
      }
    }

    assert {:ok, result} = WebAuthn.verify_assertion(credential, challenge_b64, public_key)
    assert result.credential_id == raw_id
    assert result.sign_count == sign_count
  end

  test "verify_assertion/4 enforces user verification unless disabled" do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)
    raw_id = "credential-id"

    flags = 0x01
    sign_count = 1
    authenticator_data = authenticator_data(flags, sign_count)

    challenge_b64 = b64url("challenge")
    client_data = client_data_json("webauthn.get", challenge_b64)

    signed = authenticator_data <> :crypto.hash(:sha256, client_data)
    signature = :crypto.sign(:ecdsa, :sha256, signed, [private_key, :prime256v1])

    credential = %{
      "rawId" => b64url(raw_id),
      "response" => %{
        "authenticatorData" => b64url(authenticator_data),
        "clientDataJSON" => b64url(client_data),
        "signature" => b64url(signature)
      }
    }

    assert {:error, :invalid_payload} =
             WebAuthn.verify_assertion(credential, challenge_b64, public_key)

    assert {:ok, _result} =
             WebAuthn.verify_assertion(credential, challenge_b64, public_key,
               require_user_verification?: false
             )
  end
end

