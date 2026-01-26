defmodule Egregoros.PleromaMigration.PostgresClient.PostgrexTest do
  use ExUnit.Case, async: true

  alias Egregoros.PleromaMigration.PostgresClient.Postgrex, as: Client

  test "can run a simple query" do
    opts =
      Egregoros.Repo.config()
      |> Keyword.take([:hostname, :username, :password, :database, :port, :ssl])
      |> Keyword.put_new(:pool_size, 1)

    {:ok, conn} = Client.start_link(opts)
    result = Client.query!(conn, "SELECT 1", [])

    assert %Postgrex.Result{rows: [[1]]} = result

    assert :ok = Client.stop(conn)
  end
end
