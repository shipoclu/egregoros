defmodule Egregoros.Repo.Migrations.AddThreadRepliesCheckedAtToObjects do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :thread_replies_checked_at, :utc_datetime_usec
    end
  end
end
