defmodule Egregoros.Repo.Migrations.AddLastActivityAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :last_activity_at, :utc_datetime_usec
    end

    create index(:users, [:last_activity_at])
  end
end
