defmodule PleromaRedux.Repo.Migrations.AddProfileFieldsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :email, :text
      add :password_hash, :text
      add :name, :text
      add :bio, :text
      add :avatar_url, :text
    end

    create unique_index(:users, [:email])
  end
end
