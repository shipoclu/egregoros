defmodule Egregoros.Repo.Migrations.AddAdminToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :admin, :boolean, default: false, null: false
    end

    execute("UPDATE users SET admin = TRUE WHERE local = TRUE AND nickname = 'alice'")
  end

  def down do
    alter table(:users) do
      remove :admin
    end
  end
end

