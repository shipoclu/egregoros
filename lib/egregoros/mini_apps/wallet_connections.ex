defmodule Egregoros.MiniApps.WalletConnections do
  @moduledoc false

  import Ecto.Query

  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.Origin
  alias Egregoros.MiniApps.Permissions
  alias Egregoros.MiniApps.WalletConnection
  alias Egregoros.Repo

  @address ~r/^0x[0-9a-fA-F]{40}$/

  def connect(user_id, app_origin, accounts)
      when is_binary(user_id) and is_binary(app_origin) and is_list(accounts) do
    with {:ok, app_origin} <- Origin.parse_origin(app_origin),
         true <- Declarations.wallet_enabled?(app_origin) or {:error, :wallet_not_declared},
         {:ok, accounts} <- normalize_accounts(accounts) do
      now = DateTime.utc_now()

      %WalletConnection{user_id: user_id}
      |> WalletConnection.changeset(%{
        app_origin: app_origin,
        accounts: accounts,
        connected_at: now
      })
      |> Repo.insert(
        conflict_target: [:user_id, :app_origin],
        on_conflict: {:replace, [:accounts, :connected_at, :updated_at]},
        returning: true
      )
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_connection}
    end
  end

  def connect(_user_id, _app_origin, _accounts), do: {:error, :invalid_connection}

  def accounts(user_id, app_origin) when is_binary(user_id) and is_binary(app_origin) do
    if Declarations.wallet_enabled?(app_origin) do
      case Repo.get_by(WalletConnection, user_id: user_id, app_origin: app_origin) do
        %WalletConnection{accounts: accounts} -> accounts
        _ -> []
      end
    else
      []
    end
  rescue
    ArgumentError -> []
    Ecto.Query.CastError -> []
  end

  def accounts(_user_id, _app_origin), do: []

  def connected?(user_id, app_origin), do: accounts(user_id, app_origin) != []

  def list_for_user(user_id) when is_binary(user_id) do
    from(connection in WalletConnection,
      where: connection.user_id == ^user_id,
      order_by: [desc: connection.connected_at, asc: connection.app_origin]
    )
    |> Repo.all()
  rescue
    ArgumentError -> []
    Ecto.Query.CastError -> []
  end

  def list_for_user(_user_id), do: []

  def revoke(user_id, app_origin) when is_binary(user_id) and is_binary(app_origin) do
    {count, _rows} =
      from(connection in WalletConnection,
        where: connection.user_id == ^user_id and connection.app_origin == ^app_origin
      )
      |> Repo.delete_all()

    if count > 0, do: Permissions.notify_revoked(user_id, app_origin, :wallet)

    :ok
  rescue
    ArgumentError -> :ok
    Ecto.Query.CastError -> :ok
  end

  def revoke(_user_id, _app_origin), do: :ok

  defp normalize_accounts(accounts) when length(accounts) in 1..16 do
    if Enum.all?(accounts, &(is_binary(&1) and String.match?(&1, @address))) do
      {:ok, accounts |> Enum.map(&String.downcase/1) |> Enum.uniq()}
    else
      {:error, :invalid_accounts}
    end
  end

  defp normalize_accounts(_accounts), do: {:error, :invalid_accounts}
end
