defmodule Egregoros.Repo.Migrations.AddOauthPkceAndTokenFamilies do
  use Ecto.Migration

  def up do
    alter table(:oauth_authorization_codes) do
      add :code_challenge, :string
      add :code_challenge_method, :string
    end

    alter table(:oauth_tokens) do
      add :family_id, :string
      add :consumed_at, :utc_datetime_usec
    end

    execute("UPDATE oauth_tokens SET family_id = id::text WHERE family_id IS NULL")

    alter table(:oauth_tokens) do
      modify :family_id, :string, null: false
    end

    create index(:oauth_tokens, [:family_id])
    create index(:oauth_tokens, [:consumed_at])
  end

  def down do
    drop index(:oauth_tokens, [:consumed_at])
    drop index(:oauth_tokens, [:family_id])

    alter table(:oauth_tokens) do
      remove :consumed_at
      remove :family_id
    end

    alter table(:oauth_authorization_codes) do
      remove :code_challenge_method
      remove :code_challenge
    end
  end
end
