defmodule PleromaRedux.Marker do
  use Ecto.Schema

  import Ecto.Changeset

  schema "markers" do
    field :timeline, :string
    field :last_read_id, :string
    field :version, :integer, default: 1

    belongs_to :user, PleromaRedux.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(marker, attrs) do
    marker
    |> cast(attrs, [:user_id, :timeline, :last_read_id, :version])
    |> validate_required([:user_id, :timeline, :last_read_id, :version])
    |> unique_constraint(:timeline, name: :markers_user_id_timeline_index)
  end
end
