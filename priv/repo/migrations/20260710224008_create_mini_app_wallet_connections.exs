defmodule Egregoros.Repo.Migrations.CreateMiniAppWalletConnections do
  use Ecto.Migration

  def change do
    create table(:mini_app_wallet_connections, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :app_origin, :text, null: false
      add :accounts, {:array, :text}, null: false
      add :connected_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mini_app_wallet_connections, [:user_id, :app_origin])
    create index(:mini_app_wallet_connections, [:app_origin])
  end
end
