defmodule PleromaRedux.User do
  use Ecto.Schema

  import Ecto.Changeset

  @fields ~w(nickname ap_id inbox outbox public_key private_key local email password_hash name bio avatar_url)a
  @required_fields ~w(nickname ap_id inbox outbox public_key local)a

  schema "users" do
    field :nickname, :string
    field :ap_id, :string
    field :inbox, :string
    field :outbox, :string
    field :public_key, :string
    field :private_key, :string
    field :local, :boolean, default: true
    field :email, :string
    field :password_hash, :string
    field :name, :string
    field :bio, :string
    field :avatar_url, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> maybe_require_private_key()
    |> validate_email_format()
    |> unique_constraint(:ap_id)
    |> unique_constraint(:nickname)
    |> unique_constraint(:email)
  end

  defp maybe_require_private_key(changeset) do
    if Ecto.Changeset.get_field(changeset, :local) do
      validate_required(changeset, [:private_key])
    else
      changeset
    end
  end

  defp validate_email_format(changeset) do
    validate_format(changeset, :email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
  end
end
