defmodule Egregoros.Repo.Migrations.AddMediaPathsIndexToObjects do
  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX objects_local_media_paths_internal_gin_index
    ON objects USING GIN (internal jsonb_path_ops)
    WHERE local = TRUE
    """)
  end

  def down do
    execute("DROP INDEX objects_local_media_paths_internal_gin_index")
  end
end
