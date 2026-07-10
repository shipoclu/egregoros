defmodule Egregoros.Repo.Migrations.CreateMiniAppCards do
  use Ecto.Migration

  def change do
    create table(:mini_app_cards, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :object_id, references(:objects, type: :uuid, on_delete: :delete_all), null: false
      add :source_url, :text, null: false
      add :app_origin, :text, null: false
      add :app_name, :text, null: false
      add :title, :text, null: false
      add :button_title, :text, null: false
      add :launch_url, :text, null: false
      add :image_url, :text
      add :resolved_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mini_app_cards, [:object_id])
    create index(:mini_app_cards, [:app_origin])
    create index(:mini_app_cards, [:expires_at])
  end
end
