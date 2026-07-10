defmodule Egregoros.MiniApps.WalletConnection do
  use Ecto.Schema

  import Ecto.Changeset

  alias Egregoros.MiniApps.Origin

  @primary_key {:id, FlakeId.Ecto.Type, autogenerate: true}
  @foreign_key_type FlakeId.Ecto.Type
  @address ~r/^0x[0-9a-f]{40}$/

  schema "mini_app_wallet_connections" do
    belongs_to :user, Egregoros.User
    field :app_origin, :string
    field :accounts, {:array, :string}, default: []
    field :connected_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:app_origin, :accounts, :connected_at])
    |> validate_required([:user_id, :app_origin, :accounts, :connected_at])
    |> validate_length(:app_origin, max: 255)
    |> validate_origin()
    |> validate_accounts()
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

  defp validate_accounts(changeset) do
    validate_change(changeset, :accounts, fn :accounts, accounts ->
      if is_list(accounts) and accounts != [] and length(accounts) <= 16 and
           Enum.all?(accounts, &(is_binary(&1) and String.match?(&1, @address))) and
           Enum.uniq(accounts) == accounts do
        []
      else
        [accounts: "must contain unique Ethereum addresses"]
      end
    end)
  end
end
