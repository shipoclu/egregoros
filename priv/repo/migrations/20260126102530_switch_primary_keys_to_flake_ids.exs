defmodule Egregoros.Repo.Migrations.SwitchPrimaryKeysToFlakeIds do
  use Ecto.Migration

  alias Ecto.Adapters.SQL
  alias FlakeId.Worker, as: FlakeWorker

  @batch_size 1_000

  def up do
    {:ok, _} = Application.ensure_all_started(:flake_id)

    # Primary keys
    for table <- ~w(
      users
      objects
      relationships
      oauth_applications
      oauth_authorization_codes
      oauth_tokens
      markers
      e2ee_keys
      e2ee_key_wrappers
      e2ee_actor_keys
      passkey_credentials
      relays
      instance_settings
      scheduled_statuses
    )a do
      alter table(table) do
        add :id_uuid, :uuid
      end
    end

    # Foreign keys
    alter table(:markers) do
      add :user_id_uuid, :uuid
    end

    alter table(:e2ee_keys) do
      add :user_id_uuid, :uuid
    end

    alter table(:e2ee_key_wrappers) do
      add :user_id_uuid, :uuid
    end

    alter table(:passkey_credentials) do
      add :user_id_uuid, :uuid
    end

    alter table(:scheduled_statuses) do
      add :user_id_uuid, :uuid
    end

    alter table(:oauth_authorization_codes) do
      add :user_id_uuid, :uuid
      add :application_id_uuid, :uuid
    end

    alter table(:oauth_tokens) do
      add :user_id_uuid, :uuid
      add :application_id_uuid, :uuid
    end

    alter table(:users) do
      add :notifications_last_seen_id_uuid, :uuid
    end

    flush()

    # Backfill new IDs (preserve relative ordering by processing legacy ids asc).
    Enum.each(
      ~w(
        users
        objects
        relationships
        oauth_applications
        oauth_authorization_codes
        oauth_tokens
        markers
        e2ee_keys
        e2ee_key_wrappers
        e2ee_actor_keys
        passkey_credentials
        relays
        instance_settings
        scheduled_statuses
      ),
      fn table ->
        backfill_id_uuid!(table)
      end
    )

    # Backfill foreign keys by joining on legacy ids.
    execute("""
    UPDATE markers AS m
    SET user_id_uuid = u.id_uuid
    FROM users AS u
    WHERE m.user_id = u.id
    """)

    execute("""
    UPDATE e2ee_keys AS k
    SET user_id_uuid = u.id_uuid
    FROM users AS u
    WHERE k.user_id = u.id
    """)

    execute("""
    UPDATE e2ee_key_wrappers AS k
    SET user_id_uuid = u.id_uuid
    FROM users AS u
    WHERE k.user_id = u.id
    """)

    execute("""
    UPDATE passkey_credentials AS c
    SET user_id_uuid = u.id_uuid
    FROM users AS u
    WHERE c.user_id = u.id
    """)

    execute("""
    UPDATE scheduled_statuses AS s
    SET user_id_uuid = u.id_uuid
    FROM users AS u
    WHERE s.user_id = u.id
    """)

    execute("""
    UPDATE oauth_authorization_codes AS c
    SET user_id_uuid = u.id_uuid
    FROM users AS u
    WHERE c.user_id = u.id
    """)

    execute("""
    UPDATE oauth_authorization_codes AS c
    SET application_id_uuid = a.id_uuid
    FROM oauth_applications AS a
    WHERE c.application_id = a.id
    """)

    execute("""
    UPDATE oauth_tokens AS t
    SET user_id_uuid = u.id_uuid
    FROM users AS u
    WHERE t.user_id = u.id
    """)

    execute("""
    UPDATE oauth_tokens AS t
    SET application_id_uuid = a.id_uuid
    FROM oauth_applications AS a
    WHERE t.application_id = a.id
    """)

    # We don't attempt to migrate "last seen" values across the ID change.
    execute("UPDATE users SET notifications_last_seen_id_uuid = NULL")

    # Enforce non-null constraints for new columns where required.
    execute("ALTER TABLE users ALTER COLUMN id_uuid SET NOT NULL")
    execute("ALTER TABLE objects ALTER COLUMN id_uuid SET NOT NULL")
    execute("ALTER TABLE relationships ALTER COLUMN id_uuid SET NOT NULL")
    execute("ALTER TABLE oauth_applications ALTER COLUMN id_uuid SET NOT NULL")
    execute("ALTER TABLE oauth_authorization_codes ALTER COLUMN id_uuid SET NOT NULL")
    execute("ALTER TABLE oauth_tokens ALTER COLUMN id_uuid SET NOT NULL")
    execute("ALTER TABLE markers ALTER COLUMN id_uuid SET NOT NULL")
    execute("ALTER TABLE e2ee_keys ALTER COLUMN id_uuid SET NOT NULL")
    execute("ALTER TABLE e2ee_key_wrappers ALTER COLUMN id_uuid SET NOT NULL")
    execute("ALTER TABLE e2ee_actor_keys ALTER COLUMN id_uuid SET NOT NULL")
    execute("ALTER TABLE passkey_credentials ALTER COLUMN id_uuid SET NOT NULL")
    execute("ALTER TABLE relays ALTER COLUMN id_uuid SET NOT NULL")
    execute("ALTER TABLE instance_settings ALTER COLUMN id_uuid SET NOT NULL")
    execute("ALTER TABLE scheduled_statuses ALTER COLUMN id_uuid SET NOT NULL")

    execute("ALTER TABLE markers ALTER COLUMN user_id_uuid SET NOT NULL")
    execute("ALTER TABLE e2ee_keys ALTER COLUMN user_id_uuid SET NOT NULL")
    execute("ALTER TABLE e2ee_key_wrappers ALTER COLUMN user_id_uuid SET NOT NULL")
    execute("ALTER TABLE passkey_credentials ALTER COLUMN user_id_uuid SET NOT NULL")
    execute("ALTER TABLE scheduled_statuses ALTER COLUMN user_id_uuid SET NOT NULL")
    execute("ALTER TABLE oauth_authorization_codes ALTER COLUMN user_id_uuid SET NOT NULL")
    execute("ALTER TABLE oauth_authorization_codes ALTER COLUMN application_id_uuid SET NOT NULL")
    execute("ALTER TABLE oauth_tokens ALTER COLUMN application_id_uuid SET NOT NULL")

    # Drop legacy foreign key constraints + dependent indexes.
    drop_if_exists constraint(:markers, "markers_user_id_fkey")
    drop_if_exists index(:markers, [:user_id, :timeline], name: :markers_user_id_timeline_index)

    drop_if_exists constraint(:e2ee_keys, "e2ee_keys_user_id_fkey")
    drop_if_exists index(:e2ee_keys, [:user_id])
    drop_if_exists index(:e2ee_keys, [:user_id, :kid])
    drop_if_exists index(:e2ee_keys, [:user_id], name: :e2ee_keys_one_active_per_user)

    drop_if_exists constraint(:e2ee_key_wrappers, "e2ee_key_wrappers_user_id_fkey")
    drop_if_exists index(:e2ee_key_wrappers, [:user_id])
    drop_if_exists index(:e2ee_key_wrappers, [:user_id, :kid])
    drop_if_exists index(:e2ee_key_wrappers, [:user_id, :kid, :type])

    drop_if_exists constraint(:passkey_credentials, "passkey_credentials_user_id_fkey")
    drop_if_exists index(:passkey_credentials, [:user_id])

    drop_if_exists constraint(:scheduled_statuses, "scheduled_statuses_user_id_fkey")
    drop_if_exists index(:scheduled_statuses, [:user_id, :scheduled_at, :id])
    drop_if_exists index(:scheduled_statuses, [:user_id, :id])

    drop_if_exists constraint(
                     :oauth_authorization_codes,
                     "oauth_authorization_codes_user_id_fkey"
                   )

    drop_if_exists constraint(
                     :oauth_authorization_codes,
                     "oauth_authorization_codes_application_id_fkey"
                   )

    drop_if_exists index(:oauth_authorization_codes, [:user_id])
    drop_if_exists index(:oauth_authorization_codes, [:application_id])

    drop_if_exists constraint(:oauth_tokens, "oauth_tokens_user_id_fkey")
    drop_if_exists constraint(:oauth_tokens, "oauth_tokens_application_id_fkey")
    drop_if_exists index(:oauth_tokens, [:user_id])
    drop_if_exists index(:oauth_tokens, [:application_id])

    # Drop indexes that reference legacy integer IDs explicitly.
    drop_if_exists index(:objects, [:type, :id], name: :objects_type_id_index)
    drop_if_exists index(:objects, [:actor, :type, :id], name: :objects_actor_type_id_index)

    drop_if_exists index(:objects, [:type, :object, :id], name: :objects_type_object_id_index)

    drop_if_exists index(:objects, [:id], name: :objects_note_has_media_id_index)

    drop_if_exists index(:objects, [:in_reply_to_ap_id, :id],
                     name: :objects_in_reply_to_ap_id_id_index
                   )

    drop_if_exists index(:objects, [:context, :published, :id],
                     name: :objects_status_context_published_id_index
                   )

    flush()

    # Drop legacy ID columns and replace with UUID Flake IDs.
    migrate_table_pk!(:users)
    migrate_table_pk!(:objects)
    migrate_table_pk!(:relationships)
    migrate_table_pk!(:oauth_applications)
    migrate_table_pk!(:oauth_authorization_codes)
    migrate_table_pk!(:oauth_tokens)
    migrate_table_pk!(:markers)
    migrate_table_pk!(:e2ee_keys)
    migrate_table_pk!(:e2ee_key_wrappers)
    migrate_table_pk!(:e2ee_actor_keys)
    migrate_table_pk!(:passkey_credentials)
    migrate_table_pk!(:relays)
    migrate_table_pk!(:instance_settings)
    migrate_table_pk!(:scheduled_statuses)

    # Swap foreign key columns now that the referenced PKs are UUID.
    migrate_fk_column!(:markers, :user_id, :user_id_uuid)
    migrate_fk_column!(:e2ee_keys, :user_id, :user_id_uuid)
    migrate_fk_column!(:e2ee_key_wrappers, :user_id, :user_id_uuid)
    migrate_fk_column!(:passkey_credentials, :user_id, :user_id_uuid)
    migrate_fk_column!(:scheduled_statuses, :user_id, :user_id_uuid)
    migrate_fk_column!(:oauth_authorization_codes, :user_id, :user_id_uuid)
    migrate_fk_column!(:oauth_authorization_codes, :application_id, :application_id_uuid)
    migrate_fk_column!(:oauth_tokens, :user_id, :user_id_uuid)
    migrate_fk_column!(:oauth_tokens, :application_id, :application_id_uuid)
    migrate_fk_column!(:users, :notifications_last_seen_id, :notifications_last_seen_id_uuid)

    # Recreate foreign key constraints.
    execute("""
    ALTER TABLE markers
    ADD CONSTRAINT markers_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE e2ee_keys
    ADD CONSTRAINT e2ee_keys_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE e2ee_key_wrappers
    ADD CONSTRAINT e2ee_key_wrappers_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE passkey_credentials
    ADD CONSTRAINT passkey_credentials_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE scheduled_statuses
    ADD CONSTRAINT scheduled_statuses_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE oauth_authorization_codes
    ADD CONSTRAINT oauth_authorization_codes_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE oauth_authorization_codes
    ADD CONSTRAINT oauth_authorization_codes_application_id_fkey
    FOREIGN KEY (application_id) REFERENCES oauth_applications(id) ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE oauth_tokens
    ADD CONSTRAINT oauth_tokens_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE oauth_tokens
    ADD CONSTRAINT oauth_tokens_application_id_fkey
    FOREIGN KEY (application_id) REFERENCES oauth_applications(id) ON DELETE CASCADE
    """)

    # Recreate indexes affected by column swaps.
    create unique_index(:markers, [:user_id, :timeline])
    create index(:e2ee_keys, [:user_id])
    create unique_index(:e2ee_keys, [:user_id, :kid])

    create unique_index(:e2ee_keys, [:user_id],
             where: "active",
             name: :e2ee_keys_one_active_per_user
           )

    create index(:e2ee_key_wrappers, [:user_id])
    create index(:e2ee_key_wrappers, [:user_id, :kid])
    create unique_index(:e2ee_key_wrappers, [:user_id, :kid, :type])

    create index(:passkey_credentials, [:user_id])
    create index(:scheduled_statuses, [:user_id, :scheduled_at, :id])
    create index(:scheduled_statuses, [:user_id, :id])
    create index(:oauth_authorization_codes, [:user_id])
    create index(:oauth_authorization_codes, [:application_id])
    create index(:oauth_tokens, [:user_id])
    create index(:oauth_tokens, [:application_id])

    create index(:objects, [:type, :id], name: :objects_type_id_index)
    create index(:objects, [:actor, :type, :id], name: :objects_actor_type_id_index)

    create index(:objects, [:type, :object, :id],
             name: :objects_type_object_id_index,
             where: "object IS NOT NULL"
           )

    create index(:objects, [:id],
             name: :objects_note_has_media_id_index,
             where: "type = 'Note' AND has_media = true"
           )

    create index(:objects, [:in_reply_to_ap_id, :id],
             name: :objects_in_reply_to_ap_id_id_index,
             where: "type = 'Note' AND in_reply_to_ap_id IS NOT NULL"
           )

    create index(:objects, [:context, :published, :id],
             name: :objects_status_context_published_id_index,
             where: "type IN ('Note', 'Announce', 'Question') AND context IS NOT NULL"
           )
  end

  def down do
    raise "Switching primary keys to flake IDs is not reversible"
  end

  defp backfill_id_uuid!(table) when is_binary(table) do
    repo = repo()

    Stream.unfold(0, fn last_id ->
      result =
        SQL.query!(
          repo,
          "SELECT id FROM #{table} WHERE id_uuid IS NULL AND id > $1 ORDER BY id LIMIT $2",
          [last_id, @batch_size]
        )

      case result.rows do
        [] ->
          nil

        rows ->
          ids = Enum.map(rows, fn [id] -> id end)
          {ids, List.last(ids)}
      end
    end)
    |> Enum.each(fn ids ->
      Enum.each(ids, fn id ->
        SQL.query!(
          repo,
          "UPDATE #{table} SET id_uuid = $1::uuid WHERE id = $2",
          [FlakeWorker.get(), id]
        )
      end)
    end)

    :ok
  end

  defp migrate_table_pk!(table) when is_atom(table) do
    table_str = Atom.to_string(table)

    execute("ALTER TABLE #{table_str} DROP CONSTRAINT #{table_str}_pkey")
    rename table(table), :id, to: :legacy_id
    rename table(table), :id_uuid, to: :id

    execute("ALTER TABLE #{table_str} ALTER COLUMN id SET NOT NULL")
    execute("ALTER TABLE #{table_str} ADD PRIMARY KEY (id)")
  end

  defp migrate_fk_column!(table, legacy_column, uuid_column)
       when is_atom(table) and is_atom(legacy_column) and is_atom(uuid_column) do
    alter table(table) do
      remove legacy_column
    end

    rename table(table), uuid_column, to: legacy_column
  end
end
