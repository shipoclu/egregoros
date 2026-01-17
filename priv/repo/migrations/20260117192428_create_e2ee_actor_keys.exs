defmodule Egregoros.Repo.Migrations.CreateE2eeActorKeys do
  use Ecto.Migration

  def change do
    create table(:e2ee_actor_keys) do
      add :actor_ap_id, :string, null: false
      add :kid, :string, null: false
      add :jwk, :map, null: false
      add :fingerprint, :string
      add :position, :integer, null: false
      add :present, :boolean, null: false, default: true
      add :fetched_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:e2ee_actor_keys, [:actor_ap_id, :kid])
    create index(:e2ee_actor_keys, [:actor_ap_id, :present, :position])
  end
end
