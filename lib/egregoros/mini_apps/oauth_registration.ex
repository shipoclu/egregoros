defmodule Egregoros.MiniApps.OAuthRegistration do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, FlakeId.Ecto.Type, autogenerate: true}
  @foreign_key_type FlakeId.Ecto.Type

  schema "mini_app_oauth_registrations" do
    belongs_to :oauth_application, Egregoros.OAuth.Application
    field :app_origin, :string
    field :redirect_uris, {:array, :string}
    field :scopes, {:array, :string}
    field :scope_authorization_max_age_seconds, :map, default: %{}
    field :capabilities, {:array, :string}
    field :manifest_fingerprint, :binary
    field :registered_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(registration, attrs) do
    registration
    |> cast(attrs, [
      :oauth_application_id,
      :app_origin,
      :redirect_uris,
      :scopes,
      :scope_authorization_max_age_seconds,
      :capabilities,
      :manifest_fingerprint,
      :registered_at
    ])
    |> validate_required([
      :oauth_application_id,
      :app_origin,
      :redirect_uris,
      :scopes,
      :manifest_fingerprint,
      :registered_at
    ])
    |> unique_constraint(:app_origin)
    |> unique_constraint(:oauth_application_id)
    |> foreign_key_constraint(:oauth_application_id)
  end
end
