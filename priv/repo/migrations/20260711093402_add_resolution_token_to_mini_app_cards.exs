defmodule Egregoros.Repo.Migrations.AddResolutionTokenToMiniAppCards do
  use Ecto.Migration

  def up do
    alter table(:mini_app_cards) do
      add :resolution_token, :uuid
    end

    execute("UPDATE mini_app_cards SET resolution_token = gen_random_uuid()")

    alter table(:mini_app_cards) do
      modify :resolution_token, :uuid, null: false
    end

    create unique_index(:mini_app_cards, [:resolution_token])
  end

  def down do
    alter table(:mini_app_cards) do
      remove :resolution_token
    end
  end
end
