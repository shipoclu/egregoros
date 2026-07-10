defmodule Egregoros.Repo.Migrations.CreateMiniAppDeclarations do
  use Ecto.Migration

  def change do
    create table(:mini_app_declarations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :app_origin, :text, null: false
      add :oauth_redirect_uris, {:array, :text}, null: false, default: []
      add :oauth_scopes, {:array, :text}, null: false, default: []
      add :capabilities, {:array, :text}, null: false, default: []
      add :wallet_evm_enabled, :boolean, null: false, default: false
      add :wallet_evm_required, :boolean, null: false, default: false
      add :wallet_evm_required_chains, {:array, :text}, null: false, default: []
      add :manifest_fingerprint, :binary, null: false
      add :declared_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mini_app_declarations, [:app_origin])
  end
end
