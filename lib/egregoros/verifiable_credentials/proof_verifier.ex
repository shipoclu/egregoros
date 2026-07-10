defmodule Egregoros.VerifiableCredentials.ProofVerifier do
  @moduledoc false

  @behaviour Egregoros.CredentialProofVerifier

  alias Egregoros.Federation.Actor
  alias Egregoros.User
  alias Egregoros.Users
  alias Egregoros.VerifiableCredentials.AssertionMethod
  alias Egregoros.VerifiableCredentials.DataIntegrity
  alias Egregoros.VerifiableCredentials.DidWeb

  @max_future_skew_seconds 300

  @impl true
  def verify(%{} = credential, %{} = context) do
    issuer = issuer_id(credential)
    actor_ap_id = Map.get(context, :actor_ap_id) || issuer

    with issuer when is_binary(issuer) and issuer != "" <- issuer,
         actor_ap_id when is_binary(actor_ap_id) and actor_ap_id != "" <- actor_ap_id,
         %{} = proof <- Map.get(credential, "proof"),
         "assertionMethod" <- Map.get(proof, "proofPurpose"),
         verification_method when is_binary(verification_method) and verification_method != "" <-
           Map.get(proof, "verificationMethod"),
         :ok <- validate_issuer_actor(issuer, actor_ap_id),
         :ok <- validate_recipient(credential, context),
         :ok <- validate_temporal(credential, proof),
         {:ok, public_key} <- resolve_public_key(issuer, actor_ap_id, verification_method),
         {:ok, true} <- DataIntegrity.verify_proof(credential, public_key) do
      :ok
    else
      nil -> {:error, :missing_proof}
      false -> {:error, :invalid_proof}
      {:ok, false} -> {:error, :invalid_proof}
      {:error, _} = error -> error
      _ -> {:error, :invalid_proof}
    end
  end

  def verify(_credential, _context), do: {:error, :invalid_proof}

  defp validate_issuer_actor(issuer, actor_ap_id) do
    cond do
      DidWeb.did_web?(issuer) -> :ok
      issuer == actor_ap_id -> :ok
      true -> {:error, :issuer_actor_mismatch}
    end
  end

  defp validate_recipient(credential, context) do
    expected = Map.get(context, :recipient_ap_id)
    actual = recipient_id(credential)

    if is_binary(expected) and expected != "" and actual == expected,
      do: :ok,
      else: {:error, :recipient_mismatch}
  end

  defp resolve_public_key(issuer, actor_ap_id, verification_method) do
    if DidWeb.did_web?(issuer) do
      DidWeb.resolve_public_key(verification_method, actor_ap_id)
    else
      with %User{} = user <- fetch_actor(issuer),
           assertion_method when not is_nil(assertion_method) <- user.assertion_method do
        AssertionMethod.find_ed25519_public_key(
          assertion_method,
          verification_method,
          issuer
        )
      else
        _ -> {:error, :missing_key}
      end
    end
  end

  defp fetch_actor(actor_ap_id) do
    case Users.get_by_ap_id(actor_ap_id) do
      %User{} = user ->
        user

      nil ->
        case Actor.fetch_and_store(actor_ap_id) do
          {:ok, %User{} = user} -> user
          _ -> nil
        end
    end
  end

  defp validate_temporal(credential, proof) do
    now = DateTime.utc_now()

    with :ok <- not_in_future(Map.get(proof, "created"), now),
         :ok <- active_at(Map.get(credential, "validFrom"), now),
         :ok <- not_expired(Map.get(credential, "validUntil"), now) do
      :ok
    end
  end

  defp not_in_future(value, now) do
    with {:ok, datetime} <- parse_datetime(value),
         true <-
           DateTime.compare(datetime, DateTime.add(now, @max_future_skew_seconds, :second)) in [
             :lt,
             :eq
           ] do
      :ok
    else
      _ -> {:error, :invalid_proof_time}
    end
  end

  defp active_at(nil, _now), do: :ok

  defp active_at(value, now) do
    with {:ok, datetime} <- parse_datetime(value),
         true <- DateTime.compare(datetime, now) in [:lt, :eq] do
      :ok
    else
      _ -> {:error, :credential_not_active}
    end
  end

  defp not_expired(nil, _now), do: :ok

  defp not_expired(value, now) do
    with {:ok, datetime} <- parse_datetime(value),
         true <- DateTime.after?(datetime, now) do
      :ok
    else
      _ -> {:error, :credential_expired}
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid_datetime}

  defp issuer_id(%{"issuer" => %{"id" => id}}) when is_binary(id), do: String.trim(id)
  defp issuer_id(%{"issuer" => id}) when is_binary(id), do: String.trim(id)
  defp issuer_id(_credential), do: nil

  defp recipient_id(%{"credentialSubject" => subject}) do
    subject
    |> List.wrap()
    |> Enum.find_value(fn
      %{"id" => id} when is_binary(id) -> String.trim(id)
      id when is_binary(id) -> String.trim(id)
      _ -> nil
    end)
  end

  defp recipient_id(_credential), do: nil
end
