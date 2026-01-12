defmodule Egregoros.Repo.Migrations.CreateInstanceSettings do
  use Ecto.Migration

  def change do
    create table(:instance_settings) do
      add :registrations_open, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end

    execute("""
    INSERT INTO instance_settings (id, registrations_open, inserted_at, updated_at)
    VALUES (1, true, now(), now());
    """)
  end
end

