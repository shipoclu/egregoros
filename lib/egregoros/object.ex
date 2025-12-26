defmodule Egregoros.Object do
  use Ecto.Schema

  import Ecto.Changeset

  @required_fields ~w(ap_id type data)a
  @optional_fields ~w(actor object published local)a

  schema "objects" do
    field :ap_id, :string
    field :type, :string
    field :actor, :string
    field :object, :string
    field :data, :map
    field :published, :utc_datetime_usec
    field :local, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(object, attrs) do
    object
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:ap_id)
  end
end
