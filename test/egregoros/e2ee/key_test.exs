defmodule Egregoros.E2EE.KeyTest do
  use ExUnit.Case, async: true

  alias Egregoros.E2EE.Key

  test "changeset adds an error when public_key_jwk is an empty map" do
    changeset =
      Key.changeset(%Key{}, %{
        user_id: 1,
        kid: "kid",
        public_key_jwk: %{},
        fingerprint: "sha256:fp",
        active: true
      })

    assert {"must be a valid JWK with kty/crv/x/y", _} = changeset.errors[:public_key_jwk]
  end

  test "changeset adds an error when public_key_jwk is not a map" do
    changeset =
      Key.changeset(%Key{}, %{
        user_id: 1,
        kid: "kid",
        public_key_jwk: "not-a-map",
        fingerprint: "sha256:fp",
        active: true
      })

    assert {"must be a valid JWK map", _} = changeset.errors[:public_key_jwk]
  end
end
