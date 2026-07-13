defmodule Egregoros.OAuth.AuthorizationCode do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, FlakeId.Ecto.Type, autogenerate: true}
  @foreign_key_type FlakeId.Ecto.Type

  @required_fields ~w(code redirect_uri expires_at user_id application_id)a
  @optional_fields ~w(scopes code_challenge code_challenge_method grant_expires_at)a

  schema "oauth_authorization_codes" do
    field :code, :string
    field :redirect_uri, :string
    field :scopes, :string, default: ""
    field :expires_at, :utc_datetime_usec
    field :grant_expires_at, :utc_datetime_usec
    field :code_challenge, :string
    field :code_challenge_method, :string

    belongs_to :user, Egregoros.User
    belongs_to :application, Egregoros.OAuth.Application

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(code, attrs) do
    code
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:code, min: 10, max: 255)
    |> validate_length(:redirect_uri, min: 1, max: 2000)
    |> validate_length(:code_challenge, min: 43, max: 128)
    |> validate_inclusion(:code_challenge_method, ["S256"])
    |> unique_constraint(:code)
  end
end
