defmodule PleromaRedux.Repo.Migrations.AddDomainToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :domain, :text
    end

    execute("""
    UPDATE users
    SET domain = substring(ap_id from 'https?://([^/]+)')
    WHERE local = false AND domain IS NULL
    """)

    drop_if_exists index(:users, [:nickname])

    create unique_index(:users, [:nickname], where: "local", name: :users_local_nickname_index)

    create unique_index(:users, [:nickname, :domain],
             where: "NOT local",
             name: :users_remote_nickname_domain_index
           )

    create constraint(:users, :remote_domain_required, check: "local OR domain IS NOT NULL")
  end

  def down do
    drop constraint(:users, :remote_domain_required)

    drop_if_exists index(:users, [:nickname, :domain], name: :users_remote_nickname_domain_index)
    drop_if_exists index(:users, [:nickname], name: :users_local_nickname_index)

    create unique_index(:users, [:nickname])

    alter table(:users) do
      remove :domain
    end
  end
end
