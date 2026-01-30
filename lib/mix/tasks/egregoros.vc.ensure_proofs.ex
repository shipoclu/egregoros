defmodule Mix.Tasks.Egregoros.Vc.EnsureProofs do
  use Mix.Task

  @shortdoc "Add proofs to local VCs and remove ActivityStreams context"

  @moduledoc """
  Add Data Integrity proofs to locally issued verifiable credentials that are
  missing proofs, removing the ActivityStreams context first if present.

  Usage:

      mix egregoros.vc.ensure_proofs
      mix egregoros.vc.ensure_proofs --dry-run
      mix egregoros.vc.ensure_proofs --limit 100
  """

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, args, _invalid} =
      OptionParser.parse(argv,
        strict: [dry_run: :boolean, limit: :integer, batch_size: :integer]
      )

    if args != [] do
      Mix.raise("""
      invalid arguments

      Usage:
        mix egregoros.vc.ensure_proofs [--dry-run] [--limit N] [--batch-size N]
      """)
    end

    case Egregoros.VerifiableCredentials.Reproof.ensure_local_credentials(opts) do
      {:ok, summary} ->
        Mix.shell().info("ensure proofs complete:")
        Mix.shell().info("  updated: #{summary.updated}")
        Mix.shell().info("  skipped: #{summary.skipped}")
        Mix.shell().info("  errors: #{summary.errors}")

      {:error, reason} ->
        Mix.raise("ensure proofs failed: #{inspect(reason)}")
    end
  end
end
