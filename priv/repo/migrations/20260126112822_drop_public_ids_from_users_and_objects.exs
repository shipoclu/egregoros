defmodule Egregoros.Repo.Migrations.DropPublicIdsFromUsersAndObjects do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE users DROP COLUMN IF EXISTS public_id")
    execute("ALTER TABLE objects DROP COLUMN IF EXISTS public_id")
  end

  def down do
    execute("ALTER TABLE users ADD COLUMN public_id uuid")
    execute("ALTER TABLE objects ADD COLUMN public_id uuid")
  end
end
