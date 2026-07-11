defmodule Egregoros.MiniApps.NotificationAudit do
  use Ecto.Schema

  import Ecto.Changeset

  @events [
    :permission_granted,
    :permission_denied,
    :permission_revoked,
    :delivery_accepted,
    :delivery_suppressed
  ]

  @primary_key {:id, FlakeId.Ecto.Type, autogenerate: true}

  schema "mini_app_notification_audits" do
    field :user_id, FlakeId.Ecto.Type
    field :app_origin, :string
    field :app_actor_url, :string
    field :event, Ecto.Enum, values: @events
    field :reason, :string
    field :occurred_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(audit, attrs) do
    audit
    |> cast(attrs, [:app_origin, :app_actor_url, :event, :reason, :occurred_at])
    |> validate_required([:user_id, :app_origin, :app_actor_url, :event, :occurred_at])
    |> validate_length(:app_origin, max: 255)
    |> validate_length(:app_actor_url, max: 2_048)
    |> validate_length(:reason, max: 64)
  end
end
