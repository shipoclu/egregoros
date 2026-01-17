defmodule Egregoros.E2EE.ActorKey do
  use Ecto.Schema

  import Ecto.Changeset

  @fields ~w(actor_ap_id kid jwk fingerprint position present fetched_at)a
  @required_fields ~w(actor_ap_id kid jwk position present fetched_at)a

  schema "e2ee_actor_keys" do
    field :actor_ap_id, :string
    field :kid, :string
    field :jwk, :map
    field :fingerprint, :string
    field :position, :integer
    field :present, :boolean, default: true
    field :fetched_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_length(:kid, max: 255)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_public_key_jwk()
    |> unique_constraint([:actor_ap_id, :kid])
  end

  defp validate_public_key_jwk(changeset) do
    case get_field(changeset, :jwk) do
      %{"kty" => kty, "crv" => crv, "x" => x, "y" => y}
      when is_binary(kty) and is_binary(crv) and is_binary(x) and is_binary(y) ->
        changeset

      %{} ->
        add_error(changeset, :jwk, "must be a valid JWK with kty/crv/x/y")

      _ ->
        add_error(changeset, :jwk, "must be a valid JWK map")
    end
  end
end
