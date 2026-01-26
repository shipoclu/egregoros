defmodule Egregoros.Passkeys.Credential do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, FlakeId.Ecto.Type, autogenerate: true}
  @foreign_key_type FlakeId.Ecto.Type

  schema "passkey_credentials" do
    field :credential_id, :binary
    field :public_key, :binary
    field :sign_count, :integer, default: 0
    field :last_used_at, :utc_datetime_usec

    belongs_to :user, Egregoros.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:user_id, :credential_id, :public_key, :sign_count, :last_used_at])
    |> validate_required([:user_id, :credential_id, :public_key])
    |> unique_constraint(:credential_id)
  end
end
