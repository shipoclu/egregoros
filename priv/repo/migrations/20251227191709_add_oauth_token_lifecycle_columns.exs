defmodule Egregoros.Repo.Migrations.AddOauthTokenLifecycleColumns do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE oauth_tokens ADD COLUMN IF NOT EXISTS refresh_token varchar")
    execute("ALTER TABLE oauth_tokens ADD COLUMN IF NOT EXISTS expires_at timestamp(6)")
    execute("ALTER TABLE oauth_tokens ADD COLUMN IF NOT EXISTS refresh_expires_at timestamp(6)")

    create_if_not_exists(unique_index(:oauth_tokens, [:refresh_token]))
    create_if_not_exists(index(:oauth_tokens, [:expires_at]))
    create_if_not_exists(index(:oauth_tokens, [:refresh_expires_at]))
  end

  def down do
    drop_if_exists(index(:oauth_tokens, [:refresh_expires_at]))
    drop_if_exists(index(:oauth_tokens, [:expires_at]))
    drop_if_exists(unique_index(:oauth_tokens, [:refresh_token]))

    execute("ALTER TABLE oauth_tokens DROP COLUMN IF EXISTS refresh_expires_at")
    execute("ALTER TABLE oauth_tokens DROP COLUMN IF EXISTS expires_at")
    execute("ALTER TABLE oauth_tokens DROP COLUMN IF EXISTS refresh_token")
  end
end
