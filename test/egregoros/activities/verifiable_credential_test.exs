defmodule Egregoros.Activities.VerifiableCredentialTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.Activities.VerifiableCredential
  alias Egregoros.BadgeDefinition
  alias Egregoros.CredentialProofVerifier
  alias Egregoros.Keys
  alias Egregoros.Pipeline
  alias Egregoros.Repo
  alias Egregoros.Users
  alias Egregoros.VerifiableCredentials.AssertionMethod
  alias Egregoros.VerifiableCredentials.DataIntegrity
  alias Egregoros.VerifiableCredentials.ProofVerifier

  setup :verify_on_exit!

  test "build_for_badge omits ActivityStreams context" do
    {:ok, badge} = insert_badge_definition("ContextBadge")

    credential =
      VerifiableCredential.build_for_badge(
        badge,
        "https://example.com/users/issuer",
        "https://example.com/users/recipient"
      )

    contexts = List.wrap(credential["@context"])

    assert "https://www.w3.org/ns/credentials/v2" in contexts
    assert "https://purl.imsglobal.org/spec/ob/v3p0/context-3.0.3.json" in contexts
    refute "https://www.w3.org/ns/activitystreams" in contexts

    assert Enum.any?(contexts, fn
             %{"to" => %{"@id" => "https://www.w3.org/ns/activitystreams#to"}} -> true
             _ -> false
           end)
  end

  test "remote ingestion calls the credential proof verifier and fails closed" do
    {:ok, recipient} = Users.create_local_user("credential-proof-recipient")

    {:ok, issuer} =
      Users.create_user(%{
        nickname: "credential-issuer",
        ap_id: "https://issuer.example/users/credential-issuer",
        inbox: "https://issuer.example/users/credential-issuer/inbox",
        outbox: "https://issuer.example/users/credential-issuer/outbox",
        public_key: "remote-key",
        local: false
      })

    credential = %{
      "id" => "https://issuer.example/credentials/unverified",
      "type" => "VerifiableCredential",
      "issuer" => issuer.ap_id,
      "to" => [recipient.ap_id],
      "credentialSubject" => %{"id" => recipient.ap_id}
    }

    CredentialProofVerifier.put_impl(CredentialProofVerifier.Mock)
    on_exit(&CredentialProofVerifier.clear_impl/0)

    expect(CredentialProofVerifier.Mock, :verify, fn received, context ->
      assert received["id"] == credential["id"]
      assert context.actor_ap_id == issuer.ap_id
      assert context.recipient_ap_id == recipient.ap_id
      {:error, :missing_proof}
    end)

    assert {:error, :invalid_credential_proof} =
             Pipeline.ingest(credential, local: false, skip_inbox_target: true)
  end

  test "the default verifier accepts a valid issuer-bound Data Integrity proof" do
    {:ok, recipient} = Users.create_local_user("valid-credential-proof-recipient")
    {ed25519_public_key, ed25519_private_key} = Keys.generate_ed25519_keypair()
    issuer_ap_id = "https://issuer.example/users/valid-issuer"

    {:ok, assertion_method} =
      AssertionMethod.from_ed25519_public_key(issuer_ap_id, ed25519_public_key)

    {:ok, _issuer} =
      Users.create_user(%{
        nickname: "valid-issuer",
        ap_id: issuer_ap_id,
        inbox: issuer_ap_id <> "/inbox",
        outbox: issuer_ap_id <> "/outbox",
        public_key: "remote-key",
        assertion_method: assertion_method,
        local: false
      })

    unsigned = %{
      "@context" => ["https://www.w3.org/ns/credentials/v2"],
      "id" => "https://issuer.example/credentials/verified",
      "type" => "VerifiableCredential",
      "issuer" => issuer_ap_id,
      "to" => [recipient.ap_id],
      "validFrom" => DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601(),
      "credentialSubject" => %{"id" => recipient.ap_id}
    }

    assert {:ok, credential} =
             DataIntegrity.attach_proof(unsigned, ed25519_private_key, %{
               "verificationMethod" => issuer_ap_id <> "#ed25519-key",
               "proofPurpose" => "assertionMethod"
             })

    assert {:ok, stored} =
             Pipeline.ingest(credential, local: false, skip_inbox_target: true)

    assert stored.ap_id == credential["id"]

    assert {:error, :issuer_actor_mismatch} =
             ProofVerifier.verify(credential, %{
               actor_ap_id: "https://issuer.example/users/mallory",
               recipient_ap_id: recipient.ap_id
             })

    assert {:error, :recipient_mismatch} =
             ProofVerifier.verify(credential, %{
               actor_ap_id: issuer_ap_id,
               recipient_ap_id: "https://issuer.example/users/someone-else"
             })
  end

  test "the default verifier rejects a remote credential without a proof" do
    {:ok, recipient} = Users.create_local_user("missing-credential-proof-recipient")
    issuer_ap_id = "https://issuer.example/users/missing-proof"

    {:ok, _issuer} =
      Users.create_user(%{
        nickname: "missing-proof",
        ap_id: issuer_ap_id,
        inbox: issuer_ap_id <> "/inbox",
        outbox: issuer_ap_id <> "/outbox",
        public_key: "remote-key",
        local: false
      })

    credential = %{
      "id" => "https://issuer.example/credentials/missing-proof",
      "type" => "VerifiableCredential",
      "issuer" => issuer_ap_id,
      "to" => [recipient.ap_id],
      "credentialSubject" => %{"id" => recipient.ap_id}
    }

    assert {:error, :invalid_credential_proof} =
             Pipeline.ingest(credential, local: false, skip_inbox_target: true)
  end

  defp insert_badge_definition(badge_type) do
    %BadgeDefinition{}
    |> BadgeDefinition.changeset(%{
      badge_type: badge_type,
      name: badge_type,
      description: "#{badge_type} badge",
      narrative: "Issued for #{badge_type}",
      disabled: false
    })
    |> Repo.insert()
  end
end
