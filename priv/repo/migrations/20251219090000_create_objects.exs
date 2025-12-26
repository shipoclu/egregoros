defmodule Egregoros.Repo.Migrations.CreateObjects do
  use Ecto.Migration

  def change do
    create table(:objects) do
      add :ap_id, :text, null: false
      add :type, :text, null: false
      add :actor, :text
      add :object, :text
      add :data, :map, null: false
      add :published, :utc_datetime_usec
      add :local, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:objects, [:ap_id])
    create index(:objects, [:actor])
    create index(:objects, [:type])
    create index(:objects, [:published])
    create index(:objects, [:local])
  end
end
