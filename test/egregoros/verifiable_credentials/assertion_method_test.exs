defmodule Egregoros.VerifiableCredentials.AssertionMethodTest do
  use ExUnit.Case, async: true

  alias Egregoros.Keys
  alias Egregoros.VerifiableCredentials.AssertionMethod

  @actor_ap_id "https://example.com/users/issuer"
  @public_key_multibase "z6MkrJVnaZkeFzdQyMZu1cgjg7k1pZZ6pvBQ7XJPt4swbTQ2"
  @verification_method @actor_ap_id <> "#ed25519-key"

  defp method(id) do
    %{
      "id" => id,
      "type" => "Multikey",
      "controller" => "https://example.com/users/issuer",
      "publicKeyMultibase" => @public_key_multibase
    }
  end

  test "matches full verificationMethod id" do
    {:ok, public_key} = Keys.ed25519_public_key_from_multibase(@public_key_multibase)

    assertion_method = [method(@verification_method)]

    assert {:ok, ^public_key} =
             AssertionMethod.find_ed25519_public_key(
               assertion_method,
               @verification_method,
               @actor_ap_id
             )
  end

  test "matches fragment verificationMethod id" do
    {:ok, public_key} = Keys.ed25519_public_key_from_multibase(@public_key_multibase)

    assertion_method = [method(@verification_method)]

    assert {:ok, ^public_key} =
             AssertionMethod.find_ed25519_public_key(
               assertion_method,
               "#ed25519-key",
               @actor_ap_id
             )
  end

  test "matches bare verificationMethod id" do
    {:ok, public_key} = Keys.ed25519_public_key_from_multibase(@public_key_multibase)

    assertion_method = [method(@verification_method)]

    assert {:ok, ^public_key} =
             AssertionMethod.find_ed25519_public_key(
               assertion_method,
               "ed25519-key",
               @actor_ap_id
             )
  end

  test "matches fragment key id against full verificationMethod" do
    {:ok, public_key} = Keys.ed25519_public_key_from_multibase(@public_key_multibase)

    assertion_method = [method("#ed25519-key")]

    assert {:ok, ^public_key} =
             AssertionMethod.find_ed25519_public_key(
               assertion_method,
               @verification_method,
               @actor_ap_id
             )
  end

  test "matches bare key id against full verificationMethod" do
    {:ok, public_key} = Keys.ed25519_public_key_from_multibase(@public_key_multibase)

    assertion_method = [method("ed25519-key")]

    assert {:ok, ^public_key} =
             AssertionMethod.find_ed25519_public_key(
               assertion_method,
               @verification_method,
               @actor_ap_id
             )
  end

  test "rejects verificationMethod from a different actor" do
    {:ok, _public_key} = Keys.ed25519_public_key_from_multibase(@public_key_multibase)

    assertion_method = [method(@verification_method)]

    assert {:error, :verification_method_mismatch} =
             AssertionMethod.find_ed25519_public_key(
               assertion_method,
               "https://evil.example/users/issuer#ed25519-key",
               @actor_ap_id
             )
  end

  test "rejects key when controller does not match actor" do
    {:ok, _public_key} = Keys.ed25519_public_key_from_multibase(@public_key_multibase)

    assertion_method = [
      %{
        "id" => @verification_method,
        "type" => "Multikey",
        "controller" => "https://evil.example/users/issuer",
        "publicKeyMultibase" => @public_key_multibase
      }
    ]

    assert {:error, :missing_key} =
             AssertionMethod.find_ed25519_public_key(
               assertion_method,
               @verification_method,
               @actor_ap_id
             )
  end

  test "rejects key ids anchored to a different actor" do
    {:ok, _public_key} = Keys.ed25519_public_key_from_multibase(@public_key_multibase)

    assertion_method = [
      %{
        "id" => "https://evil.example/users/issuer#ed25519-key",
        "type" => "Multikey",
        "controller" => @actor_ap_id,
        "publicKeyMultibase" => @public_key_multibase
      }
    ]

    assert {:error, :missing_key} =
             AssertionMethod.find_ed25519_public_key(
               assertion_method,
               @verification_method,
               @actor_ap_id
             )
  end
end
