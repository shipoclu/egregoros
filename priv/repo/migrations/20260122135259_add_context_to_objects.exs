defmodule Egregoros.Repo.Migrations.AddContextToObjects do
  use Ecto.Migration

  def change do
    execute(
      """
      ALTER TABLE objects
      ADD COLUMN context text GENERATED ALWAYS AS (
        CASE
          WHEN jsonb_typeof(data->'context') = 'string' THEN NULLIF(btrim(data->>'context'), '')
          ELSE NULL
        END
      ) STORED
      """,
      "ALTER TABLE objects DROP COLUMN context"
    )

    create index(:objects, [:context, :published, :id],
             name: :objects_status_context_published_id_index,
             where: "type IN ('Note', 'Announce', 'Question') AND context IS NOT NULL"
           )
  end
end
