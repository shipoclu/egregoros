defmodule Egregoros.Repo.Migrations.AddRemoteFollowCountsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :remote_followers_count, :integer
      add :remote_following_count, :integer
      add :remote_counts_checked_at, :utc_datetime_usec
    end
  end
end
