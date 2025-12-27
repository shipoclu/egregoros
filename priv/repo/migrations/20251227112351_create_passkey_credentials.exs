defmodule Egregoros.Repo.Migrations.CreatePasskeyCredentials do
  use Ecto.Migration

  def change do
    create table(:passkey_credentials) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :sign_count, :bigint, null: false, default: 0
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:passkey_credentials, [:user_id])
    create unique_index(:passkey_credentials, [:credential_id])
  end
end
