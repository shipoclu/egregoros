defmodule Egregoros.Repo.Migrations.AddMiniAppActivityPubAndNotificationConsents do
  use Ecto.Migration

  def change do
    alter table(:mini_app_declarations) do
      add :activity_pub_actor_url, :text
      add :activity_pub_public_notes, :boolean, null: false, default: false
      add :activity_pub_transactional_mentions, :boolean, null: false, default: false
    end

    create table(:mini_app_notification_consents, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :app_origin, :text, null: false
      add :app_actor_url, :text, null: false
      add :decision, :text, null: false
      add :decided_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mini_app_notification_consents, [:user_id, :app_origin])
    create index(:mini_app_notification_consents, [:app_origin])
    create index(:mini_app_notification_consents, [:app_actor_url])

    create constraint(:mini_app_notification_consents, :valid_decision,
             check: "decision IN ('granted', 'denied')"
           )
  end
end
