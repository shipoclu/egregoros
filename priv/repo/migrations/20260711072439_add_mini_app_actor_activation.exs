defmodule Egregoros.Repo.Migrations.AddMiniAppActorActivation do
  use Ecto.Migration

  def change do
    alter table(:mini_app_declarations) do
      add :activity_pub_actor_fingerprint, :binary
      add :activity_pub_actor_activated_at, :utc_datetime_usec
    end

    create index(:mini_app_declarations, [:activity_pub_actor_url])
  end
end
