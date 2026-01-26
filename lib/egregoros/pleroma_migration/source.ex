defmodule Egregoros.PleromaMigration.Source do
  @moduledoc false

  @callback list_users(keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback list_statuses(keyword()) :: {:ok, [map()]} | {:error, term()}

  def list_users(opts \\ []) when is_list(opts) do
    impl().list_users(opts)
  end

  def list_statuses(opts \\ []) when is_list(opts) do
    impl().list_statuses(opts)
  end

  defp impl do
    Egregoros.Config.get(__MODULE__, Egregoros.PleromaMigration.Source.Postgres)
  end
end
