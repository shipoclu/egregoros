defmodule Egregoros.PleromaMigration.PostgresClient do
  @moduledoc false

  @callback start_link(keyword()) :: {:ok, pid() | term()} | {:error, term()}
  @callback query!(term(), iodata(), list(), keyword()) :: %{rows: [list()]} | term()
  @callback stop(term()) :: :ok

  def start_link(opts) when is_list(opts) do
    impl().start_link(opts)
  end

  def query!(conn, sql, params) when is_list(params) do
    query!(conn, sql, params, [])
  end

  def query!(conn, sql, params, opts) when is_list(params) and is_list(opts) do
    impl().query!(conn, sql, params, opts)
  end

  def stop(conn) do
    impl().stop(conn)
  end

  defp impl do
    Egregoros.Config.get(__MODULE__, Egregoros.PleromaMigration.PostgresClient.Postgrex)
  end
end
