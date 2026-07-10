defmodule Egregoros.Repo.Migrations.CreateMiniAppOauthRegistrations do
  use Ecto.Migration

  def change do
    create table(:mini_app_oauth_registrations, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :oauth_application_id,
          references(:oauth_applications, type: :uuid, on_delete: :delete_all),
          null: false

      add :app_origin, :text, null: false
      add :redirect_uris, {:array, :text}, null: false
      add :scopes, {:array, :text}, null: false
      add :capabilities, {:array, :text}, null: false
      add :manifest_fingerprint, :binary, null: false
      add :registered_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mini_app_oauth_registrations, [:app_origin])
    create unique_index(:mini_app_oauth_registrations, [:oauth_application_id])
  end
end
