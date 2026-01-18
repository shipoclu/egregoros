defmodule Egregoros.E2EE.ActorKeyTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.E2EE.ActorKey

  test "changeset validates the jwk payload" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    valid =
      %ActorKey{}
      |> ActorKey.changeset(%{
        actor_ap_id: "https://remote.example/users/alice",
        kid: "e2ee-alice",
        jwk: %{"kty" => "EC", "crv" => "P-256", "x" => "x", "y" => "y"},
        fingerprint: "sha256:abc",
        position: 0,
        present: true,
        fetched_at: now
      })

    assert valid.valid?

    invalid =
      %ActorKey{}
      |> ActorKey.changeset(%{
        actor_ap_id: "https://remote.example/users/alice",
        kid: "e2ee-alice",
        jwk: %{"kty" => "EC"},
        fingerprint: "sha256:abc",
        position: 0,
        present: true,
        fetched_at: now
      })

    refute invalid.valid?
    assert %{jwk: [_ | _]} = errors_on(invalid)
  end
end
