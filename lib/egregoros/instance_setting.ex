defmodule Egregoros.InstanceSetting do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, FlakeId.Ecto.Type, autogenerate: true}
  @foreign_key_type FlakeId.Ecto.Type

  schema "instance_settings" do
    field :registrations_open, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:registrations_open])
    |> validate_required([:registrations_open])
  end
end
