defmodule Egregoros.Repo.Migrations.AddKindToOauthApplications do
  use Ecto.Migration

  def change do
    alter table(:oauth_applications) do
      add :kind, :string
    end

    create constraint(:oauth_applications, :oauth_applications_kind_check,
             check: "kind IS NULL OR kind = 'miniapp'"
           )
  end
end
