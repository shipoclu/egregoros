defmodule Egregoros.Relay do
  use Ecto.Schema

  import Ecto.Changeset

  @fields ~w(ap_id)a

  schema "relays" do
    field :ap_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(relay, attrs) do
    relay
    |> cast(attrs, @fields)
    |> validate_required([:ap_id])
    |> unique_constraint(:ap_id)
  end
end
