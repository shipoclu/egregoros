defmodule Egregoros.Repo.Migrations.AddNotificationsLastSeenIdToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :notifications_last_seen_id, :bigint, null: false, default: 0
    end
  end
end

