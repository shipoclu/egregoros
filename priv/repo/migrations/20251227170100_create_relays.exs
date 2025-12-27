defmodule Egregoros.Repo.Migrations.CreateRelays do
  use Ecto.Migration

  def change do
    create table(:relays) do
      add :ap_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:relays, [:ap_id])
  end
end
