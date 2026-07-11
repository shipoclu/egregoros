defmodule Egregoros.MiniApps.Card do
  use Ecto.Schema

  import Ecto.Changeset

  alias Egregoros.MiniApps.Origin

  @primary_key {:id, FlakeId.Ecto.Type, autogenerate: true}
  @foreign_key_type FlakeId.Ecto.Type
  @required_fields ~w(
    object_id resolution_token source_url app_origin app_name title button_title launch_url
    resolved_at expires_at
  )a
  @optional_fields ~w(image_url)a

  schema "mini_app_cards" do
    belongs_to :object, Egregoros.Object
    field :resolution_token, Ecto.UUID
    field :source_url, :string
    field :app_origin, :string
    field :app_name, :string
    field :title, :string
    field :button_title, :string
    field :launch_url, :string
    field :image_url, :string
    field :resolved_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(card, attrs) do
    card
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:source_url, max: 2_048)
    |> validate_length(:app_origin, max: 255)
    |> validate_length(:app_name, min: 1, max: 64)
    |> validate_length(:title, min: 1, max: 80)
    |> validate_length(:button_title, min: 1, max: 32)
    |> validate_length(:launch_url, max: 2_048)
    |> validate_length(:image_url, max: 2_048)
    |> validate_exact_origin(:source_url)
    |> validate_exact_origin(:launch_url)
    |> validate_exact_origin(:image_url)
    |> unique_constraint(:object_id)
    |> foreign_key_constraint(:object_id)
  end

  defp validate_exact_origin(changeset, field) do
    origin = get_field(changeset, :app_origin)

    validate_change(changeset, field, fn ^field, value ->
      case Origin.validate_url(value, origin) do
        :ok -> []
        _ -> [{field, "is not on the app origin"}]
      end
    end)
  end
end
