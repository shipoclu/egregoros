defmodule Egregoros.Repo.Migrations.CreateMiniAppContextConsents do
  use Ecto.Migration

  def change do
    create table(:mini_app_context_consents, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :app_origin, :text, null: false
      add :approved_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mini_app_context_consents, [:user_id, :app_origin])
    create index(:mini_app_context_consents, [:app_origin])
  end
end
