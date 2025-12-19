defmodule PleromaRedux.Repo.Migrations.BackfillLikeAndAnnounceRelationships do
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO relationships (type, actor, object, activity_ap_id, inserted_at, updated_at)
    SELECT type, actor, object, ap_id, NOW(), NOW()
    FROM (
      SELECT DISTINCT ON (type, actor, object) type, actor, object, ap_id
      FROM objects
      WHERE type IN ('Like', 'Announce')
      ORDER BY type, actor, object, inserted_at DESC NULLS LAST, id DESC
    ) latest
    ON CONFLICT (type, actor, object) DO UPDATE
      SET activity_ap_id = EXCLUDED.activity_ap_id,
          updated_at = EXCLUDED.updated_at;
    """)
  end

  def down do
    :ok
  end
end
