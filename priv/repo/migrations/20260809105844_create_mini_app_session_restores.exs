defmodule Egregoros.Repo.Migrations.CreateMiniAppSessionRestores do
  use Ecto.Migration

  def change do
    create table(:mini_app_session_restores, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :code_digest, :string, null: false
      add :restore_challenge, :string, null: false
      add :app_origin, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec

      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false

      add :oauth_application_id,
          references(:oauth_applications, type: :uuid, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:mini_app_session_restores, [:code_digest])
    create index(:mini_app_session_restores, [:user_id, :oauth_application_id])
    create index(:mini_app_session_restores, [:expires_at])
  end
end
