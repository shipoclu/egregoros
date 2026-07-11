defmodule Egregoros.Repo.Migrations.AddClientTypeToOauthApplications do
  use Ecto.Migration

  def up do
    alter table(:oauth_applications) do
      add :client_type, :string, null: false, default: "confidential"
    end

    execute("""
    UPDATE oauth_applications
    SET client_type = 'public_mini_app'
    WHERE id IN (
      SELECT oauth_application_id
      FROM mini_app_oauth_registrations
    )
    """)

    create constraint(:oauth_applications, :oauth_applications_client_type_check,
             check: "client_type IN ('confidential', 'public_mini_app')"
           )
  end

  def down do
    drop constraint(:oauth_applications, :oauth_applications_client_type_check)

    alter table(:oauth_applications) do
      remove :client_type
    end
  end
end
