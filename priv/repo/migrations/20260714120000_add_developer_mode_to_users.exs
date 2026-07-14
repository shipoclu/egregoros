defmodule Egregoros.Repo.Migrations.AddDeveloperModeToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :developer_mode, :boolean, default: false, null: false
    end
  end
end
