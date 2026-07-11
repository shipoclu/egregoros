defmodule Egregoros.Repo.Migrations.HardenMiniAppActorKeysAndAddNotificationAudits do
  use Ecto.Migration

  def change do
    alter table(:mini_app_declarations) do
      add :activity_pub_actor_key_id, :text
      add :activity_pub_actor_key_fingerprint, :binary
    end

    create table(:mini_app_notification_audits, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :app_origin, :text, null: false
      add :app_actor_url, :text, null: false
      add :event, :text, null: false
      add :reason, :text
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:mini_app_notification_audits, [:user_id, :occurred_at])
    create index(:mini_app_notification_audits, [:app_origin, :occurred_at])

    create constraint(:mini_app_notification_audits, :valid_event,
             check:
               "event IN ('permission_granted', 'permission_denied', 'permission_revoked', 'delivery_accepted', 'delivery_suppressed')"
           )
  end
end
