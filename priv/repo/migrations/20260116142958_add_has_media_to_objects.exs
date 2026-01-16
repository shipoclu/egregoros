defmodule Egregoros.Repo.Migrations.AddHasMediaToObjects do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :has_media, :boolean, default: false, null: false
    end

    execute(
      """
      UPDATE objects
      SET has_media =
        CASE
          WHEN jsonb_typeof(data->'attachment') = 'array' THEN jsonb_array_length(data->'attachment') > 0
          ELSE FALSE
        END
      WHERE type = 'Note'
      """,
      "UPDATE objects SET has_media = false WHERE type = 'Note'"
    )

    create index(:objects, [:id],
             name: :objects_note_has_media_id_index,
             where: "type = 'Note' AND has_media = true"
           )
  end
end
