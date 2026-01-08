defmodule Egregoros.Repo.Migrations.AddUserTrgmSearchIndexes do
  use Ecto.Migration

  def change do
    execute(
      "CREATE INDEX IF NOT EXISTS users_nickname_trgm_index\n" <>
        "ON users USING gin (nickname gin_trgm_ops)",
      "DROP INDEX IF EXISTS users_nickname_trgm_index"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS users_name_trgm_index\n" <>
        "ON users USING gin (name gin_trgm_ops)\n" <>
        "WHERE name IS NOT NULL",
      "DROP INDEX IF EXISTS users_name_trgm_index"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS users_domain_trgm_index\n" <>
        "ON users USING gin (domain gin_trgm_ops)\n" <>
        "WHERE domain IS NOT NULL",
      "DROP INDEX IF EXISTS users_domain_trgm_index"
    )
  end
end
