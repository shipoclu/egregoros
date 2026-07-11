defmodule Egregoros.Repo.Migrations.HardenMiniAppTransactionalDeliveryAudits do
  use Ecto.Migration

  def change do
    alter table(:mini_app_notification_audits) do
      add :delivery_fingerprint, :binary
    end

    create unique_index(
             :mini_app_notification_audits,
             [:user_id, :delivery_fingerprint],
             where: "delivery_fingerprint IS NOT NULL",
             name: :mini_app_notification_audits_delivery_replay_index
           )
  end
end
