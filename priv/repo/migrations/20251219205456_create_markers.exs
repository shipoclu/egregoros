defmodule Egregoros.Repo.Migrations.CreateMarkers do
  use Ecto.Migration

  def change do
    create table(:markers) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :timeline, :string, null: false
      add :last_read_id, :string, null: false
      add :version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:markers, [:user_id, :timeline])
  end
end
