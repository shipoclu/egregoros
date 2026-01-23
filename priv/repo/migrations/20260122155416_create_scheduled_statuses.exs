defmodule Egregoros.Repo.Migrations.CreateScheduledStatuses do
  use Ecto.Migration

  def change do
    create table(:scheduled_statuses) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :scheduled_at, :utc_datetime_usec, null: false
      add :params, :map, null: false, default: %{}
      add :oban_job_id, :bigint
      add :published_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scheduled_statuses, [:user_id, :scheduled_at, :id])
    create index(:scheduled_statuses, [:user_id, :id])
    create index(:scheduled_statuses, [:oban_job_id])
  end
end
