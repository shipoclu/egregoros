defmodule Egregoros.Repo.Migrations.PinMiniAppActorPublicKeys do
  use Ecto.Migration

  def up do
    alter table(:mini_app_declarations) do
      add :activity_pub_actor_public_key_pem, :text
    end

    execute("""
    UPDATE mini_app_declarations
    SET activity_pub_actor_activated_at = NULL
    WHERE activity_pub_actor_activated_at IS NOT NULL
    """)
  end

  def down do
    alter table(:mini_app_declarations) do
      remove :activity_pub_actor_public_key_pem
    end
  end
end
