defmodule Egregoros.Repo.Migrations.AddLockedToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :locked, :boolean, default: false, null: false
    end
  end
end
