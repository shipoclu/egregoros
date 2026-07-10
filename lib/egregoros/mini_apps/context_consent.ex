defmodule Egregoros.MiniApps.ContextConsent do
  use Ecto.Schema

  import Ecto.Changeset

  alias Egregoros.MiniApps.Origin

  @primary_key {:id, FlakeId.Ecto.Type, autogenerate: true}
  @foreign_key_type FlakeId.Ecto.Type

  schema "mini_app_context_consents" do
    belongs_to :user, Egregoros.User
    field :app_origin, :string
    field :approved_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(consent, attrs) do
    consent
    |> cast(attrs, [:user_id, :app_origin, :approved_at])
    |> validate_required([:user_id, :app_origin, :approved_at])
    |> validate_length(:app_origin, max: 255)
    |> validate_origin()
    |> unique_constraint([:user_id, :app_origin])
    |> foreign_key_constraint(:user_id)
  end

  defp validate_origin(changeset) do
    validate_change(changeset, :app_origin, fn :app_origin, origin ->
      case Origin.parse_origin(origin) do
        {:ok, ^origin} -> []
        _ -> [app_origin: "is invalid"]
      end
    end)
  end
end
