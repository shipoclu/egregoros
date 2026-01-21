# frozen_string_literal: true

# The official Mastodon docker image runs as a non-root user. In development mode,
# Rails defaults to dumping `db/schema.rb` after migrations, but `/opt/mastodon/db`
# is not writable in the image. For the federation-in-a-box smoke tests we don't
# need schema dumps, so disable them to keep `rails db:prepare` working.

if Rails.env.development?
  Rails.application.config.active_record.dump_schema_after_migration = false

  if defined?(ActiveRecord)
    ActiveRecord.dump_schema_after_migration = false
  end
end

