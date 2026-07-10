defmodule Egregoros.Federation.Error do
  @moduledoc """
  Classifies federation failures for job retry decisions.

  Validation, authorization, and protocol-shape failures are permanent for the
  submitted activity. Unknown failures are retried because database, DNS, and
  HTTP failures commonly arrive as adapter-specific terms.
  """

  @permanent ~w(
    invalid_args unknown_type invalid local_id unsafe_url invalid_json
    invalid_activitystreams_content_type invalid_webfinger_content_type
    invalid_webfinger_subject invalid_handle invalid_actor invalid_base58
    invalid_challenge invalid_context invalid_created invalid_credential_proof
    invalid_datetime invalid_did invalid_did_document invalid_document
    invalid_domain invalid_ed25519_key invalid_id invalid_json_key invalid_key
    invalid_key_type invalid_private_key invalid_proof invalid_proof_options
    invalid_proof_time invalid_proof_value invalid_public_key invalid_target
    invalid_type invalid_update_timestamp invalid_verification_method
    not_found not_targeted not_direct too_long unknown_object question_not_found
    unauthorized_object unauthorized_update unauthorized_verification_method
    stale_update actor_id_mismatch actor_mismatch id_authority_mismatch id_mismatch
    issuer_actor_mismatch recipient_mismatch verification_method_mismatch
    uncorrelated_follow_response missing_e2ee_payload missing_issuer missing_key
    missing_offset missing_proof missing_public_key credential_expired
    credential_not_active proof_already_present unsupported_cryptosuite
    voter_not_permitted
  )a

  def classify(reason) when reason in @permanent, do: :permanent
  def classify(%Ecto.Changeset{}), do: :permanent
  def classify(_reason), do: :transient
end
