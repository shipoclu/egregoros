defmodule Egregoros.Deployment do
  @moduledoc """
  Deployment helpers that run on boot.
  """

  require Logger

  alias Egregoros.Users

  @spec bootstrap() :: :ok
  def bootstrap do
    nickname = Egregoros.Config.get(:bootstrap_admin_nickname)

    case bootstrap_admin(nickname) do
      :ok ->
        :ok

      {:error, :user_not_found} ->
        Logger.warning("bootstrap admin user not found: #{inspect(nickname)}")
        :ok

      {:error, reason} ->
        Logger.error("bootstrap admin failed: #{inspect(reason)}")
        :ok
    end
  end

  @spec bootstrap_admin(String.t() | nil) :: :ok | {:error, term()}
  def bootstrap_admin(nil), do: :ok

  def bootstrap_admin(nickname) when is_binary(nickname) do
    nickname = String.trim(nickname)

    if nickname == "" do
      :ok
    else
      case Users.get_by_nickname(nickname) do
        nil ->
          {:error, :user_not_found}

        user ->
          case Users.set_admin(user, true) do
            {:ok, _user} -> :ok
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  def bootstrap_admin(_), do: {:error, :invalid_nickname}
end
