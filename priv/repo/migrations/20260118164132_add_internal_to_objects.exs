defmodule Egregoros.Repo.Migrations.AddInternalToObjects do
  use Ecto.Migration

  def up do
    alter table(:objects) do
      add :internal, :map, null: false, default: %{}
    end

    execute("""
    UPDATE objects
    SET internal = jsonb_set(internal, '{poll,voters}', data->'voters', true),
        data = data - 'voters'
    WHERE type = 'Question'
      AND data ? 'voters'
      AND jsonb_typeof(data->'voters') = 'array';
    """)

    execute("""
    UPDATE objects o
    SET internal = jsonb_set(
          o.internal,
          '{poll,option_voters}',
          COALESCE(
            (
              SELECT jsonb_object_agg(opt->>'name', opt->'egregoros:voters')
              FROM jsonb_array_elements(o.data->'anyOf') AS opt
              WHERE jsonb_typeof(opt) = 'object'
                AND opt ? 'name'
                AND opt ? 'egregoros:voters'
                AND jsonb_typeof(opt->'egregoros:voters') = 'array'
            ),
            '{}'::jsonb
          ),
          true
        )
    WHERE o.type = 'Question'
      AND jsonb_typeof(o.data->'anyOf') = 'array'
      AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements(o.data->'anyOf') AS opt
        WHERE jsonb_typeof(opt) = 'object' AND opt ? 'egregoros:voters'
      );
    """)

    execute("""
    UPDATE objects o
    SET data = jsonb_set(
          o.data,
          '{anyOf}',
          (
            SELECT jsonb_agg(
                     CASE
                       WHEN jsonb_typeof(opt) = 'object' THEN opt - 'egregoros:voters'
                       ELSE opt
                     END
                     ORDER BY ordinality
                   )
            FROM jsonb_array_elements(o.data->'anyOf') WITH ORDINALITY AS t(opt, ordinality)
          ),
          true
        )
    WHERE o.type = 'Question'
      AND jsonb_typeof(o.data->'anyOf') = 'array'
      AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements(o.data->'anyOf') AS opt
        WHERE jsonb_typeof(opt) = 'object' AND opt ? 'egregoros:voters'
      );
    """)

    execute("""
    UPDATE objects o
    SET data = jsonb_set(
          o.data,
          '{oneOf}',
          (
            SELECT jsonb_agg(
                     CASE
                       WHEN jsonb_typeof(opt) = 'object' THEN opt - 'egregoros:voters'
                       ELSE opt
                     END
                     ORDER BY ordinality
                   )
            FROM jsonb_array_elements(o.data->'oneOf') WITH ORDINALITY AS t(opt, ordinality)
          ),
          true
        )
    WHERE o.type = 'Question'
      AND jsonb_typeof(o.data->'oneOf') = 'array'
      AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements(o.data->'oneOf') AS opt
        WHERE jsonb_typeof(opt) = 'object' AND opt ? 'egregoros:voters'
      );
    """)
  end

  def down do
    alter table(:objects) do
      remove :internal
    end
  end
end
