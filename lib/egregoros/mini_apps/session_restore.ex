defmodule Egregoros.MiniApps.SessionRestore do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, FlakeId.Ecto.Type, autogenerate: true}
  @foreign_key_type FlakeId.Ecto.Type

  schema "mini_app_session_restores" do
    field :code_digest, :string
    field :restore_challenge, :string
    field :app_origin, :string
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec

    belongs_to :user, Egregoros.User
    belongs_to :oauth_application, Egregoros.OAuth.Application

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(restore, attrs) do
    restore
    |> cast(attrs, [
      :code_digest,
      :restore_challenge,
      :app_origin,
      :expires_at,
      :consumed_at
    ])
    |> validate_required([
      :code_digest,
      :restore_challenge,
      :app_origin,
      :expires_at,
      :user_id,
      :oauth_application_id
    ])
    |> validate_length(:code_digest, is: 64)
    |> validate_length(:restore_challenge, is: 43)
    |> validate_length(:app_origin, max: 2_048)
    |> unique_constraint(:code_digest)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:oauth_application_id)
  end
end
