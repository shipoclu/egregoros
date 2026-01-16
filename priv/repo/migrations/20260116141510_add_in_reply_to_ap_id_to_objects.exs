defmodule Egregoros.Repo.Migrations.AddInReplyToApIdToObjects do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :in_reply_to_ap_id, :string
    end

    execute(
      """
      UPDATE objects
      SET in_reply_to_ap_id = NULLIF(
        CASE
          WHEN jsonb_typeof(data->'inReplyTo') = 'string' THEN data->>'inReplyTo'
          WHEN jsonb_typeof(data->'inReplyTo') = 'object' THEN data->'inReplyTo'->>'id'
          ELSE NULL
        END,
        ''
      )
      WHERE type = 'Note'
      """,
      "UPDATE objects SET in_reply_to_ap_id = NULL WHERE type = 'Note'"
    )

    create index(:objects, [:in_reply_to_ap_id, :id],
             name: :objects_in_reply_to_ap_id_id_index,
             where: "type = 'Note' AND in_reply_to_ap_id IS NOT NULL"
           )
  end
end
