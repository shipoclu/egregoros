defmodule Egregoros.Repo.Migrations.AddMiniAppScopeAuthorizationLifetimes do
  use Ecto.Migration

  def change do
    alter table(:mini_app_oauth_registrations) do
      add :scope_authorization_max_age_seconds, :map, null: false, default: %{}
    end

    alter table(:mini_app_declarations) do
      add :oauth_scope_authorization_max_age_seconds, :map, null: false, default: %{}
    end

    alter table(:oauth_authorization_codes) do
      add :grant_expires_at, :utc_datetime_usec
    end
  end
end
