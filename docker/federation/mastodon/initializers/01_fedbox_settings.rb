# frozen_string_literal: true

# The official Mastodon docker image runs as a non-root user, and `/opt/mastodon/db`
# is not writable in the image. Rails defaults to dumping `db/schema.rb` after
# migrations, but for the federation-in-a-box smoke tests we don't need schema
# dumps, so disable them to keep `rails db:prepare` working.

Rails.application.config.active_record.dump_schema_after_migration = false

if defined?(ActiveRecord)
  ActiveRecord.dump_schema_after_migration = false
end
