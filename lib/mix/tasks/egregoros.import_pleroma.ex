defmodule Mix.Tasks.Egregoros.ImportPleroma do
  use Mix.Task

  @shortdoc "Import users + statuses from a Pleroma Postgres database"

  @moduledoc """
  Imports data from a Pleroma Postgres database into the configured Egregoros database.

  This is intended for one-shot migrations. The Pleroma database is treated as read-only.

  ## Usage

      mix egregoros.import_pleroma --url postgres://USER:PASS@HOST:5432/pleroma_db

  If `--url` is omitted, the task reads `PLEROMA_DATABASE_URL`.
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _errors} =
      OptionParser.parse(args,
        strict: [
          url: :string,
          database_url: :string
        ]
      )

    case Egregoros.PleromaMigration.run(opts) do
      %{users: users_result, statuses: statuses_result} = summary ->
        Mix.shell().info("Imported users: #{users_result.inserted}/#{users_result.attempted}")

        Mix.shell().info(
          "Imported statuses: #{statuses_result.inserted}/#{statuses_result.attempted}"
        )

        summary

      {:error, error} ->
        Mix.raise("Pleroma import failed: #{Exception.format(:error, error, [])}")

      other ->
        Mix.raise("Pleroma import failed: #{inspect(other)}")
    end
  end
end
