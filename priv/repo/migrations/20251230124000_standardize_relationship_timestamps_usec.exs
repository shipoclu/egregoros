defmodule Egregoros.Repo.Migrations.StandardizeRelationshipTimestampsUsec do
  use Ecto.Migration

  def up do
    alter table(:relationships) do
      modify :inserted_at, :utc_datetime_usec
      modify :updated_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:relationships) do
      modify :inserted_at, :utc_datetime
      modify :updated_at, :utc_datetime
    end
  end
end
