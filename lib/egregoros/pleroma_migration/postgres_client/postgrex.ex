defmodule Egregoros.PleromaMigration.PostgresClient.Postgrex do
  @moduledoc false

  @behaviour Egregoros.PleromaMigration.PostgresClient

  @impl true
  def start_link(opts) when is_list(opts) do
    Postgrex.start_link(opts)
  end

  @impl true
  def query!(conn, sql, params) when is_list(params) do
    Postgrex.query!(conn, sql, params)
  end

  @impl true
  def stop(conn) do
    GenServer.stop(conn)
  end
end
