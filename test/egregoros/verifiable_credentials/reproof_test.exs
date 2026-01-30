defmodule Egregoros.VerifiableCredentials.ReproofTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Keys
  alias Egregoros.TestSupport.Fixtures
  alias Egregoros.Users
  alias Egregoros.VerifiableCredentials.DataIntegrity
  alias Egregoros.VerifiableCredentials.Reproof
  alias EgregorosWeb.Endpoint

  @as_context "https://www.w3.org/ns/activitystreams"
  @as_public "https://www.w3.org/ns/activitystreams#Public"

  test "reproof_document removes ActivityStreams context and re-signs" do
    {:ok, issuer} = Users.create_local_user("reproof_issuer")
    {:ok, recipient} = Users.create_local_user("reproof_recipient")

    credential =
      Fixtures.json!("openbadge_vc.json")
      |> Map.put("issuer", issuer.ap_id)
      |> Map.put("id", Endpoint.url() <> "/objects/" <> Ecto.UUID.generate())
      |> Map.put("to", [recipient.ap_id, @as_public])
      |> put_in(["credentialSubject", "id"], recipient.ap_id)
      |> Map.delete("proof")

    verification_method = issuer.ap_id <> "#ed25519-key"

    {:ok, signed} =
      DataIntegrity.attach_proof(credential, issuer.ed25519_private_key, %{
        "verificationMethod" => verification_method,
        "proofPurpose" => "assertionMethod"
      })

    assert @as_context in List.wrap(signed["@context"])

    assert {:ok, updated} =
             Reproof.reproof_document(signed, issuer.ap_id, issuer.ed25519_private_key)

    contexts = List.wrap(updated["@context"])
    refute @as_context in contexts
    assert "https://www.w3.org/ns/credentials/v2" in contexts
    assert "https://purl.imsglobal.org/spec/ob/v3p0/context-3.0.3.json" in contexts
    assert updated["to"] == signed["to"]

    {:ok, public_key} = Keys.ed25519_public_key_from_private_key(issuer.ed25519_private_key)
    assert {:ok, true} = DataIntegrity.verify_proof(updated, public_key)
  end

  test "ensure_document adds proof and strips ActivityStreams context when missing proof" do
    {:ok, issuer} = Users.create_local_user("ensure_issuer")
    {:ok, recipient} = Users.create_local_user("ensure_recipient")

    credential =
      Fixtures.json!("openbadge_vc.json")
      |> Map.put("issuer", issuer.ap_id)
      |> Map.put("id", Endpoint.url() <> "/objects/" <> Ecto.UUID.generate())
      |> Map.put("to", [recipient.ap_id, @as_public])
      |> put_in(["credentialSubject", "id"], recipient.ap_id)
      |> Map.delete("proof")

    assert @as_context in List.wrap(credential["@context"])

    assert {:ok, updated} =
             Reproof.ensure_document(credential, issuer.ap_id, issuer.ed25519_private_key)

    contexts = List.wrap(updated["@context"])
    refute @as_context in contexts
    assert "https://www.w3.org/ns/credentials/v2" in contexts
    assert "https://purl.imsglobal.org/spec/ob/v3p0/context-3.0.3.json" in contexts
    assert updated["to"] == credential["to"]
    assert is_map(updated["proof"])

    {:ok, public_key} = Keys.ed25519_public_key_from_private_key(issuer.ed25519_private_key)
    assert {:ok, true} = DataIntegrity.verify_proof(updated, public_key)
  end

  test "ensure_document skips when proof is present and context unchanged" do
    {:ok, issuer} = Users.create_local_user("ensure_issuer_skip")
    {:ok, recipient} = Users.create_local_user("ensure_recipient_skip")

    contexts =
      Fixtures.json!("openbadge_vc.json")
      |> Map.get("@context")
      |> List.wrap()
      |> Enum.reject(&(&1 == @as_context))

    credential =
      Fixtures.json!("openbadge_vc.json")
      |> Map.put("@context", contexts)
      |> Map.put("issuer", issuer.ap_id)
      |> Map.put("id", Endpoint.url() <> "/objects/" <> Ecto.UUID.generate())
      |> Map.put("to", [recipient.ap_id, @as_public])
      |> put_in(["credentialSubject", "id"], recipient.ap_id)
      |> Map.delete("proof")

    verification_method = issuer.ap_id <> "#ed25519-key"

    {:ok, signed} =
      DataIntegrity.attach_proof(credential, issuer.ed25519_private_key, %{
        "verificationMethod" => verification_method,
        "proofPurpose" => "assertionMethod"
      })

    assert {:skip, :proof_present} =
             Reproof.ensure_document(signed, issuer.ap_id, issuer.ed25519_private_key)
  end

  test "reproof_document skips when ActivityStreams context is absent" do
    {:ok, issuer} = Users.create_local_user("reproof_issuer_skip")
    {:ok, recipient} = Users.create_local_user("reproof_recipient_skip")

    contexts =
      Fixtures.json!("openbadge_vc.json")
      |> Map.get("@context")
      |> List.wrap()
      |> Enum.reject(&(&1 == @as_context))

    credential =
      Fixtures.json!("openbadge_vc.json")
      |> Map.put("@context", contexts)
      |> Map.put("issuer", issuer.ap_id)
      |> Map.put("id", Endpoint.url() <> "/objects/" <> Ecto.UUID.generate())
      |> Map.put("to", [recipient.ap_id, @as_public])
      |> put_in(["credentialSubject", "id"], recipient.ap_id)
      |> Map.delete("proof")

    verification_method = issuer.ap_id <> "#ed25519-key"

    {:ok, signed} =
      DataIntegrity.attach_proof(credential, issuer.ed25519_private_key, %{
        "verificationMethod" => verification_method,
        "proofPurpose" => "assertionMethod"
      })

    assert {:skip, :context_unchanged} =
             Reproof.reproof_document(signed, issuer.ap_id, issuer.ed25519_private_key)
  end
end
