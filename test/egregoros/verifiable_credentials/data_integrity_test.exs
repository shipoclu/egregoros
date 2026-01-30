defmodule Egregoros.VerifiableCredentials.DataIntegrityTest do
  use ExUnit.Case, async: true

  alias Egregoros.Keys
  alias Egregoros.VerifiableCredentials.DataIntegrity

  @public_key_multibase "z6MkrJVnaZkeFzdQyMZu1cgjg7k1pZZ6pvBQ7XJPt4swbTQ2"
  @private_key_hex "C96EF9EA10C5E414C471723AFF9DE72C35FA5B70FAE97E8832ECAC7D2E2B8ED6"
  @verification_method "did:key:z6MkrJVnaZkeFzdQyMZu1cgjg7k1pZZ6pvBQ7XJPt4swbTQ2#z6MkrJVnaZkeFzdQyMZu1cgjg7k1pZZ6pvBQ7XJPt4swbTQ2"
  @proof_purpose "assertionMethod"
  @created "2023-02-24T23:36:38Z"
  @expected_proof_value "z2HnFSSPPBzR36zdDgK8PbEHeXbR56YF24jwMpt3R1eHXQzJDMWS93FCzpvJpwTWd3GAVFuUfjoJdcnTMuVor51aX"

  test "attach_proof matches the eddsa-jcs-2022 test vector" do
    unsigned = fixture!("vc_di_eddsa_unsigned.json")
    private_key = Base.decode16!(@private_key_hex, case: :mixed)

    assert {:ok, signed} =
             DataIntegrity.attach_proof(unsigned, private_key, %{
               "verificationMethod" => @verification_method,
               "proofPurpose" => @proof_purpose,
               "created" => @created
             })

    proof = signed["proof"]
    assert proof["proofValue"] == @expected_proof_value
    assert proof["type"] == "DataIntegrityProof"
    assert proof["cryptosuite"] == "eddsa-jcs-2022"
    assert proof["@context"] == unsigned["@context"]
  end

  test "verify_proof validates the eddsa-jcs-2022 test vector" do
    signed = fixture!("vc_di_eddsa_signed.json")
    {:ok, public_key} = Keys.ed25519_public_key_from_multibase(@public_key_multibase)

    assert {:ok, true} = DataIntegrity.verify_proof(signed, public_key)
  end

  test "verify_proof returns false for tampered content" do
    signed = fixture!("vc_di_eddsa_signed.json")
    {:ok, public_key} = Keys.ed25519_public_key_from_multibase(@public_key_multibase)

    tampered = put_in(signed, ["credentialSubject", "alumniOf"], "Tampered")

    assert {:ok, false} = DataIntegrity.verify_proof(tampered, public_key)
  end

  test "verify_proof rejects context mismatch" do
    signed = fixture!("vc_di_eddsa_signed.json")
    {:ok, public_key} = Keys.ed25519_public_key_from_multibase(@public_key_multibase)

    mismatch = Map.update!(signed, "@context", fn [first | rest] -> rest ++ [first] end)

    assert {:error, :invalid_context} = DataIntegrity.verify_proof(mismatch, public_key)
  end

  test "attach_proof rejects invalid created value" do
    unsigned = fixture!("vc_di_eddsa_unsigned.json")
    private_key = Base.decode16!(@private_key_hex, case: :mixed)

    assert {:error, :invalid_created} =
             DataIntegrity.attach_proof(unsigned, private_key, %{
               "verificationMethod" => @verification_method,
               "proofPurpose" => @proof_purpose,
               "created" => "not-a-date"
             })
  end

  defp fixture!(name) do
    "test/fixtures"
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end
end
